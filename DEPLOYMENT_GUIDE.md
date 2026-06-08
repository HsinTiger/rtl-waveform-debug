# RTL 波形 Debug Pipeline — 大規模部署 10 大問題與實戰解法

> **適用對象：** RTL Design / Verification 團隊主管與架構師
> **環境：** 氣隙工網 + EDA regression farm + Verdi/VCS
> **版本：** v1.0 (2026-06)

---

## TL;DR

這套 pipeline 在小型 PoC 運作良好，但放大到數百 regression + 全晶片規模時會撞上 10 道牆：

| # | 問題 | 嚴重度 | 優先級 |
|---|------|--------|--------|
| 1 | **VCD 肥大爆炸** — 100MB FSDB → 800MB VCD | 🔴 頭號殺手 | 立即 |
| 2 | **LLM context 裝不下** — 整檔 VCD 塞不進 1M context | 🔴 | 立即 |
| 3 | **訊號名歧義** — 大設計中 5 個同名的 `clk` | 🟡 | Phase 1 |
| 4 | **Verdi 授權瓶頸** — N 個 worker 搶 license | 🟡 | Phase 1 |
| 5 | **Regression farm 排程** — 500 個 test 都產 VCD 會 IO 爆 | 🟡 | Phase 1 |
| 6 | **Time window 對齊** — golden vs VCD 起始不對齊 | 🟢 | Phase 2 |
| 7 | **Golden hex 格式不一致** — 不同 block 不同格式 | 🟢 | Phase 2 |
| 8 | **LLM 幻覺管控** — 捏造訊號名/時間/值 = Tape-Out 風險 | 🔴 | 貫穿全局 |
| 9 | **跨機器環境一致性** — 每台機器 Verdi/Python 版本不同 | 🟡 | 部署當下 |
| 10 | **團隊採用障礙** — Designer 不信 LLM 的結論 | 🟡 | 貫穿全局 |

---

## ① VCD 肥大爆炸（#1 Killer）

### 問題

FSDB 是 Synopsys Verdi 的二進位私有格式，已包含 signal-level 壓縮與 scope 索引。當你從 FSDB 轉成 VCD 時，等於把壓縮過的資料全部解包成純文字。

| Format | 一個 full-chip 回歸 | 500 個 nightly |
|--------|---------------------|----------------|
| FSDB raw | 100 MB | 50 GB |
| **VCD（full，不切片）** | **~800 MB (8x)** | **~400 GB** |
| VCD（scope + time slice） | **~5 MB** | **~2.5 GB** |

**不經任何處理就把 FSDB 轉整份 VCD → 儲存系統直接被淹沒。**

### 解法

**① Time window slicing（最重要的單一優化）**

大部分 bug 的 root cause 在 failure time 前後 1μs 內。先用 fsdbextract 在 FSDB 域切片，再 fsdb2vcd 轉檔——切片發生在 FSDB 域（資料維持壓縮），fsdb2vcd 只負責轉換不做切片：

```bash
# Stage 1：fsdbextract 在 FSDB 域切出 1μs（FSDB→FSDB，資料仍壓縮）
sh $RTLDBG/tools/fsdbextract.sh top.fsdb -bt 100ns -et 200ns -s /tb/dut -level 0 -o slice.fsdb +grid

# Stage 2：fsdb2vcd 轉小檔（不帶任何切片旗標）
sh $RTLDBG/tools/fsdb2vcd.sh slice.fsdb -o slice.vcd
# 100μs simulation 只截 1μs → VCD 大小直接砍 99%
```

**② Scope filtering**

只切跟 failure 有關的 hierarchy scope——同樣在 fsdbextract（FSDB 域）做，scope 用 slash 表示：

```bash
# scope 切片在 FSDB 域完成（slash 形式 /tb/dut/...，-level 0 = scope 及其下所有）
sh $RTLDBG/tools/fsdbextract.sh top.fsdb -s /tb/dut/phy_ud -level 0 -o slice.fsdb +grid
sh $RTLDBG/tools/fsdb2vcd.sh slice.fsdb -o slice.vcd
```

**③ 兩層切片策略**

```bash
# 第一層：fsdbextract 在 FSDB 域粗切（FSDB→FSDB，裁掉 99% 的無關時間後再轉檔）
sh $RTLDBG/tools/fsdbextract.sh top.fsdb -bt 100ns -et 102ns -s /tb/dut -level 0 -o coarse.fsdb +grid
sh $RTLDBG/tools/fsdb2vcd.sh coarse.fsdb -o coarse.vcd

# 第二層：vcd.py/compare.py 細切（同一個 VCD 上快速切子視窗）
vcd.py wavejson coarse.vcd --t0 50500 --t1 51000 > win1.json
compare.py coarse.vcd golden.hex --t0 50500 --t1 51000
```

**④ 部署 check — 壓縮率警報**

```bash
vcd_size=$(wc -c < output.vcd)
fsdb_size=$(wc -c < input.fsdb)
ratio=$((vcd_size / fsdb_size))
if [ $ratio -gt 5 ]; then
  echo "WARNING: VCD/FSDB ratio $ratio exceeds threshold"
fi
```

---

## ② LLM Context 裝不下整個波形

### 問題

即使當代 LLM 支援 1M+ token（DeepSeek V4、Gemini 2.5），VCD 仍是對 LLM 最不友善的格式之一：

- VCD `$dumpvars` 包含大量重複初始值宣告，浪費 context
- 超過幾百行的連續變化，LLM 會開始**編造從未發生的轉態**
- Attention 是 O(n²)，1M token 不只貴而且**品質低於 2K token 的精簡查詢**

### 解法：Tool-Query Pattern（不可妥協）

```
[VCD] → vcd.py（確定性工具）→ JSON/CSV < 2KB → LLM
```

LLM **永遠不看 raw VCD**。它只能透過工具查詢：

```bash
# ❌ 不要這樣（餵 raw VCD 給 LLM）
cat dump.vcd | claude "這個波形有什麼問題？"

# ✅ 要這樣（工具查詢後餵摘要）
vcd.py changes dump.vcd tb.dut.phy_ud.data 50000 51000
compare.py dump.vcd golden.hex --skip-x
```

這個模式的好處：
1. LLM 永遠只看到小量、高價值的資料片段
2. 查詢結果是 **deterministic** 的——可以快取、可以跨 session 重現
3. 即使 LLM 全躺，pipeline 仍能產出 comparator report

---

## ③ 訊號名歧義（大規模特別嚴重）

### 問題

一個典型的 SoC hierarchy：

```
tb.soc_top.cpu0.clk
tb.soc_top.cpu1.clk
tb.soc_top.bus.clk
tb.clk
```

五個 `clk`，LLM 不知道你問哪個。

### 現有 vcd.py 的 Name Resolution

```
Step 1: exact match        → 找到唯一就回傳
Step 2: partial suffix     → 比對結尾，若唯一就回傳
Step 3: ambiguity error    → 多個 match 時 raise error
```

### 解法

1. **部署規範：始終用 canonical full name**（含完整 scope path）
2. **初始化階段先 `vcd.py list` 掃 full signal list**，存入 session metadata
3. **Agent 在任何查詢前先 validate 訊號路徑存在**
4. **建立 signal alias table** 供常見縮寫使用

```bash
# SOP
vcd.py list dump.vcd --match clk        # 確認有哪些 clk
vcd.py value dump.vcd tb.soc_top.cpu0.clk 1500    # 用 full path
```

---

## ④ Verdi 授權瓶頸

### 問題

`fsdb2vcd` 需要 Verdi license（~$100K+/year floating）。500 個 nightly regression 若多個 worker 同時轉 FSDB 會搶 license。

### 解法（四管齊下）

**① 優先讓 VCS 直接 `$dumpvars` 產 VCD（零授權成本）**

```bash
# VCS 模擬命令列直接產 VCD，不需要 Verdi
./simv +vcd+file=output.vcd +vcd+scope=tb.dut
```

**② Queue 化轉檔，限制並行數**

建立 central converter queue，限制並行度 ≤ 3（根據 license token 數）：

```bash
# 簡單 semaphore 包裝
MAX_FSDB2VCD=3
CURRENT=$(jobs -r | wc -l)
while [ "$CURRENT" -ge "$MAX_FSDB2VCD" ]; do
  sleep 5
  CURRENT=$(jobs -r | wc -l)
done
fsdb2vcd top.fsdb -o out.vcd &
```

**③ Cache 已轉的 VCD**

```bash
# 用 FSDB header 的 CRC 當 cache key — 同檔案不重轉
FSDB_HASH=$(head -c 4096 input.fsdb | cksum | awk '{print $1}')
CACHE_KEY="${FSDB_HASH}_${SCOPE}_${BT}_${ET}"
if [ -f "/cache/vcd/${CACHE_KEY}.vcd" ]; then
  cp "/cache/vcd/${CACHE_KEY}.vcd" output.vcd
else
  # 切片在 FSDB 域（fsdbextract），再轉小檔（fsdb2vcd 不做切片）
  sh $RTLDBG/tools/fsdbextract.sh input.fsdb -bt ${BT}ns -et ${ET}ns -s ${SCOPE} -level 0 -o /tmp/$$.fsdb +grid
  sh $RTLDBG/tools/fsdb2vcd.sh /tmp/$$.fsdb -o /tmp/$$.vcd
  cp /tmp/$$.vcd "/cache/vcd/${CACHE_KEY}.vcd"
  cp /tmp/$$.vcd output.vcd
fi
```

**④ 跟 Synopsys AE 談 batch/offline 授權** — 這類授權僅限後台批次使用，價格顯著低於 interactive license。

---

## ⑤ Regression Farm 排程

### 問題

500 個 nightly 每個都產 VCD = 400 GB/night，但你只需要其中 ~5%。

### 解法

**① Only on failure（最重要的防線）**

```
passing test → 不產 VCD（節省 ~95% 的儲存）
failing test → 啟動 debug pipeline
```

**② Failure warm-up：log error → auto rerun + targeted dump**

```
Step 1: 跑 regression with minimal VCD（fast, small dump）
Step 2: 檢查 log 中的 UVM_ERROR/UVM_FATAL
Step 3: 從 log 提取 error 發生的 simulation time
Step 4: 自動 rerun with full dump，但只 error time ± 500ns
```

總執行時間增加 ~20%，但 VCD 小 100 倍。

**③ 按 severity 排隊**

| Priority | Severity | 處理 |
|----------|----------|------|
| P0 | UVM_FATAL / assertion fatal | 立即 rerun + full dump |
| P1 | UVM_ERROR / data mismatch | 排入 queue，scope 覆蓋關鍵路徑 |
| P2 | UVM_WARNING | 工作日 batch 處理，minimal dump |
| P3 | Expected failure（known issue） | 不進 pipeline，僅 log |

---

## ⑥ Time Window 對齊

### 問題

C-model golden 和 VCS simulation 的時間軸通常**起始就不對齊**：

- Reset cycle count 不同（C-model 10 cycle vs RTL 50 cycle）
- Golden sampling interval 不同
- Pipelining depth 不同

### 現有解法

**① `--skip-x`（先試這個）**

跳過 VCD 中所有 `x`/`z` 的 cycle——通常 reset 期間輸出都是 `x`，跳過就對齊了。

**② `--t0 N`（當 `--skip-x` 不夠用時）**

手動指定對齊點：
```bash
# VCD 的 cycle 50 對應 golden 的 cycle 0
compare.py dump.vcd golden.hex --skip-x --t0 50
```

**③ 根本解法：讓 C-model 產 cycle-aligned hex**

```python
# golden_improved.hex
cycle=0000 result=DEAD
cycle=0001 result=BEEF
```

---

## ⑦ Golden Hex 格式不一致

### 問題

不同 IP block 的 golden dump 格式完全不同：

```
# Block A（cache controller）
cycle addr data

# Block B（arithmetic unit）  
op1: a=0x5 b=0x3 result=0x8

# Block C（DMA）
trans 1: src=0x1000 len=64 status=OK
```

### 解法

**短期：讓 cmodel_hex.py 的 adapter 處理每個 block**

現有 `cmodel_hex.py` 已內建 adapter pattern，每個 block 可自訂 parser。

**長期：推動所有 IP team 用統一格式**

```json5
// golden.json — 通用格式
[
  {"cycle": 0, "result": "DEAD", "valid": 1},
  {"cycle": 1, "result": "BEEF", "valid": 1}
]
```

JSON 天生自描述，不需要 parser。

---

## ⑧ LLM 幻覺管控（Tape-Out 風險）

### 問題

LLM 已知的幻覺行為：

| 幻覺類型 | 影響 | 實例 |
|----------|------|------|
| 虛構訊號名稱 | Pipeline 判斷錯誤 | 說 `tb.dut.debug_en` 是 1，但該訊號不存在 |
| 虛構造時間點 | 誤導 debug 方向 | 說 failure 在 1234ns，實際在 5678ns |
| 虛構造數值 | Golden 比對結果偽造 | 說 data bus 全部匹配，實際有 3 個 mismatch |

### 解法

**① SKILL.md 鐵則：所有訊號值來自確定性工具**

LLM 不能憑記憶陳述任何訊號值——必須引用 `vcd.py value` 或 `compare.py` 的輸出。

**② Cross-check：工具輸出 vs LLM Claims**

Agent 回答後自動檢測：LLM 聲稱的 signal=value@time 與工具結果是否一致。

**③ 信心分數機制**

| 標籤 | 意義 |
|------|------|
| `[DATA-SUPPORTED]` | 有工具/波形直接證據 |
| `[INFERRED]` | 從證據推論，非直接觀察 |
| `[SPECULATIVE]` | 純猜測 |

LLM 報告中若超過 30% SPECULATIVE → 標註「低信心度」。

---

## ⑨ 跨機器環境一致性

### 問題

在氣隙工網中，不同機器環境不一致是常態：

| 機器 | Verdi | Python | PATH | 結果 |
|------|-------|--------|------|------|
| dev server | v2022.06 | 3.8 | /tools/synopsys/verdi/bin | OK |
| regression farm | v2023.09 | 3.6 | 不同路徑 | fsdb2vcd not found |
| designer WS | v2024.03 | 3.11 | 無 Verdi | 需要 IT |

### 解法

**① `sh tools/_selftest.sh` → Deploy-time sanity check**

每個 pipeline deploy 時第一步先自我檢測。

**② vcd.py 是 pure Python stdlib — 零 pip 相依**

這是最被低估的優點：`vcd.py` 只使用 Python 標準函式庫——在氣隙環境中這是決定性優勢。

**③ Containerize（Docker/Singularity）**

```bash
# Singularity（氣隙首選，不需 daemon）
singularity exec /tools/debug-pipeline.sif vcd.py list dump.vcd
```

**④ Verdi 透過 `module load` 統一管理**

```bash
# 不要在 PATH 寫死 Verdi 路徑
module load synopsys/verdi/v2023.09
```

---

## ⑩ 團隊採用障礙

### 問題

RTL designers 用 Verdi GUI 拉了十幾年的波形，突然要他們信任 LLM 的 debug 結論——這是文化衝擊。

### 解法（從確定性工具建立信任）

**① 從 golden-verified cases 開始**

先不讓 LLM 分析未知 bug。先用**已知答案的 RTL bug** 跑 pipeline → 一秒定位 designer 花三小時才找到的 mismatch → 在 team meeting 上 demo。

關鍵話術：**「這不是 LLM 的分析——這是確定性工具的直接輸出。每一個 mismatch 你都可以自己用 Verdi 驗證。」**

**② Designers 可以自己驗證工具輸出**

所有工具都是 **deterministic** 的——同樣的輸入永遠產生同樣的輸出。

```bash
# Designer 自行驗證
vcd.py value dump.vcd tb.dut.result 50500
# 然後在 Verdi 中同一個時間點對照
```

**③ LLM 只解釋、不修補 RTL（部署紅線）**

```
vcd.py        → 產生 mismatch list（確定性工具）
LLM agent     → 用自然語言解釋 mismatch 的可能根源（推測性，需標注 [INFERRED]）
Designer      → 手動檢查 RTL，確認後手動修改
```

**④ 量化 ROI**

```python
# 自動追蹤
BEFORE = 45  # designer 平均 debug 時間（分鐘）
AFTER  = 15  # 用工具後（含驗證）
print(f"Improvement: {BEFORE/AFTER:.1f}x")
```

---

## 部署順序建議

| Phase | 範圍 | LLM 角色 | Designer 角色 | 驗收標準 |
|-------|------|----------|--------------|----------|
| **1. Golden Compare** | 單一 block, 已知 bug | 無（純確定性工具） | 對照 Verdi 驗證 | 3 個已知 bug 全數被工具抓到 |
| **2. LLM 輔助解釋** | 同上 + LLM 摘要 | 解釋 mismatch 原因 | 驗證 LLM 解釋 vs RTL | 5 個 bug 中解釋正確率 > 80% |
| **3. Scope 擴展** | 3 個 block | 同上 + signal query | 同上 + 提供 feedback | block 覆蓋率 100%, FP < 5% |
| **4. Nightly Integration** | Entire regression farm | 同上 + failure triage | 只 review pipeline 報告 | debug cycle 縮短 50%+ |

---

## 上線前 Check-list

```markdown
[ ] VCD blow-up guard: scope + time slicing 已實作，壓縮率 < 5x
[ ] LLM never sees raw VCD: 全部走 tool-query pattern
[ ] Signal name resolver: canonical full path, ambiguity error handling
[ ] Verdi license: queue (max 3 concurrent), cache (CRC64), VCS native VCD fallback
[ ] Regression scheduling: only on failure, severity-prioritized queue, warm-up rerun
[ ] Time alignment: --skip-x first, --t0 fallback, cycle-aligned golden preferred
[ ] Golden format: adapter pattern in place, roadmap to standardization
[ ] Hallucination control: SKILL.md rules, cross-check, confidence scoring
[ ] Environment consistency: _selftest.sh, containerized tools, pure-stdlib vcd.py
[ ] Team adoption: golden-verified cases first, LLM=explainer only, ROI tracking
```
