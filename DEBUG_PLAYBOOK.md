# Agent Debug Playbook — phyUD 驗證流程

> **適用範圍：** DD / SD / DV 協作下的 phyUD platform debug 流程
> **錯誤來源：** A) RTL behavior · B) TXCMP/RXCMP Checker · C) sim_setting.json · D) phyUD C++
> **核心原則：** Agent 提供「三大方向 + 概率」，DD 做最終判斷。工具決定「值是什麼」，Agent 解釋「為什麼」。

---

## 錯誤來源與概率分布

| 代碼 | 錯誤來源 | 概率 | 說明 |
|------|----------|------|------|
| **B** | TXCMP/RXCMP Checker 邏輯/時機 | **30–45%** | 最大宗。checker 比對時間窗錯、off-by-one、latency mismatch |
| **A** | RTL behavior 電路設計 | **25–35%** | Corner case、介面協議不一致、operating mode 路徑 |
| **C** | sim_setting.json config | **10–20%** | DV 拿到舊版/錯誤 config，參數組合非預期 |
| **D** | phyUD C++ 實作 | **5–15%** | 多數 fixed-point 精度（truncation/rounding），少數行為錯誤 |

### Check Order（最短路徑）

```
Step 1: Type C — Config Diff（最快，2 分鐘）
   ↓ 一致
Step 2: Type B — Checker Timing（30 分鐘）
   ↓ 無誤
Step 3: Type A vs D — RTL vs Spec 比對（核心判斷）
   ↓ RTL 與 spec 一致 → D（C++ 錯誤）
   RTL 與 spec 不一致 → A（RTL bug）
```

---

## Agent SOP — 8 步驟

### Step 0: 環境確認（30s）

```bash
# 確認所有必要輸入檔案存在
ls -la vcs.log top.fsdb output_data/*.hex sim_setting.json
# 確認 RTL source（含 TXCMP/ RXCMP/ checker）
find . -name "*.sv" -path "*/TXCMP/*" -o -name "*.sv" -path "*/RXCMP/*"
# 確認 phyUD C++ source
find . -name "*.cpp" -o -name "*.h" | head -20
```

### Step 1: grep vcs.log 找第一筆 Error（2 min）

```bash
# 三種 grep 策略，同時跑
grep -n -i "UVM_ERROR\|UVM_FATAL" vcs.log | head -10
grep -n "\*E,\|*E," vcs.log | head -10
grep -n "ASSERT\|FAIL\|MISMATCH" vcs.log | head -10

# 從 error 訊息中萃取時間與訊號
# 範例輸出: # UVM_ERROR @ 1525000 ps: data mismatch on tb.dut.phyUD
# → T = 1525ns, signal = tb.dut.phyUD
```

**預期輸出：** 第一個 error 的時間 `T` 與嫌疑訊號名。
**如何判斷下一步：** 取得 T 後，進入 Step 2 做 VCD time slicing。

### Step 2: FSDB → VCD 時間切片（5 min）

```bash
# 確認 FSDB timescale
fsdb2vcd -l top.fsdb | grep Timescale

# 時間切片（在 T 前後各取 100ns）
BT=$((T - 100))
ET=$((T + 100))
./tools/fsdb2vcd.sh top.fsdb --bt $BT --et $ET --scope tb.dut.phy_ud -o debug.vcd

# 如果沒有 Verdi → 確認是否有預先轉好的 VCD，用 vcd.py 的 --t0/--t1 做時間視窗
python3 tools/vcd.py wavejson debug.vcd --clk tb.clk --sig tb.dut.phyUD --t0 $BT --t1 $ET
```

**預期輸出：** 一個小於 10MB 的 debug.vcd + 時間範圍檢查。

### Step 3: vcd.py list scope 內訊號（2 min）

```bash
# 列出 scope 內所有訊號 → 找 canonical full name
python3 tools/vcd.py list debug.vcd --match phyUD

# 列出 failing checker instance 的訊號
python3 tools/vcd.py list debug.vcd --match TXCMP
python3 tools/vcd.py list debug.vcd --match RXCMP
```

**注意：** 強制使用 `vcd.py list` 回傳的 canonical full name，不要用短名。

### Step 4: vcd.py value — 取得 T 附近訊號值（3 min）

```bash
# 在 T 前後各抓 5 個時間點
python3 tools/vcd.py value debug.vcd tb.dut.phyUD $T
for dt in -10 -5 -2 -1 0 1 2 5 10; do
  python3 tools/vcd.py value debug.vcd tb.dut.phyUD $((T + dt))
done

# 同時看 checker 的 enable / act_data / exp_data
python3 tools/vcd.py value debug.vcd tb.TXCMP.enable $T
python3 tools/vcd.py value debug.vcd tb.TXCMP.exp_data $T
python3 tools/vcd.py value debug.vcd tb.TXCMP.act_data $T
```

**解讀 pattern：**
- `exp_data` vs `act_data` 數值差常數倍 → 可能是 sim_setting 的 scale factor 不對（Type C）
- `exp_data` vs `act_data` 波形形狀一樣但相位差 N cycle → checker timing 錯（Type B）
- `act_data` 有 x/z → RTL uninitialized（Type A）
- `act_data` 與 spec 一致但與 `exp_data` 差 ±1 LSB → fixed-point（Type D）
- `enable` 訊號在錯誤時間點不在 active 狀態 → checker enable 條件錯（Type B）

### Step 5: compare.py — 找 RTL vs golden 分歧點（5 min）

```bash
# 基本用法（用 --t0/--t1 限縮到錯誤時間前後）
python3 tools/compare.py debug.vcd \
  --clk tb.clk \
  --sig tb.dut.phyUD \
  output_data/phyUD.hex --node phyUD \
  --skip-x --t0 $BT --t1 $ET

# 如果第一次失敗，試不同對齊方式
python3 tools/compare.py debug.vcd \
  --clk tb.clk \
  --sig tb.dut.phyUD \
  output_data/phyUD.hex --node phyUD \
  --t0 $((BT + 50)) --t1 $ET
```

**預期 JSON 輸出：**
```json
{
  "signal": "tb.dut.phyUD",
  "match": false,
  "first_divergence": {
    "index": 12,
    "clk_time": 1525,
    "golden": "A5",
    "actual": "5A"
  }
}
```

### Step 6: cmodel_hex.py — 驗證 golden 格式（2 min）

```bash
# 確認 hex 被正確解析
python3 tools/cmodel_hex.py output_data/phyUD.hex --node phyUD | head -20

# 如果有兩份 golden（不同 sim_setting）
python3 tools/cmodel_hex.py output_data/phyUD.hex --node phyUD | wc -l
python3 tools/cmodel_hex.py output_data/phyUD_ref.hex --node phyUD | wc -l
```

**如果格式錯誤：** adapter 需修改（見 cmodel_hex.py 中的標記區塊）。

### Step 7: vcd.py wavejson — 產出 SVG 時序圖（3 min）

```bash
# 轉成 WaveJSON（含 clk + 關鍵訊號）
python3 tools/vcd.py wavejson debug.vcd \
  --clk tb.clk \
  --sig tb.dut.phyUD tb.TXCMP.enable tb.TXCMP.exp_data tb.TXCMP.act_data \
  --t0 $((T - 50)) --t1 $((T + 50)) > debug_wave.json5

# 渲染成 SVG
sh tools/render_wavedrom.sh debug_wave.json5 debug_wave.svg
```

### Step 8: 綜合判斷 → 產出最終報告（5 min）

根據前 7 步的證據，使用以下決策流程決定三大方向與概率：

```
[Step 1: Config Diff]
  ├─ 有差異 ─→ Type C (high prob) → 建議：重新拿正確 json
  └─ 無差異 ─→ 繼續

[Step 2-7: 證據累積]
  同時檢查以下指紋：

  A (RTL behavior):
    □ compare.py divergence 是 constant bias / multiple bit error
    □ vcd.py value 在 T 前後看到 x/z
    □ 跨不同 sim_setting 都 fail
    □ FSM state 進入非法狀態

  B (Checker timing):
    □ compare.py divergence 是 phase shift / cycle offset
    □ checker.exp_data vs act_data 波形形狀一致但差 N cycle
    □ checker.enable 在 T 時不在 active 狀態
    □ 只發生在特定 boundary（first/last beat）

  C (Config):
    □ vcs.log 有 "sim_setting loaded: <path>" 指向非預期路徑
    □ hex data 與 RTL 數值有 scale factor 關係
    □ 同 test 換 config 後結果不同

  D (C++):
    □ divergence 是 ±1 LSB / truncation pattern
    □ RTL 行為與 spec 一致（手動確認）
    □ 跨多個 checker 同時 fail（因全部參考同一個 hex）
```

**最終報告格式：**
```markdown
---
**🕐 錯誤時間定位**：T = ${T}ns，signal = ${SIG}

**🔍 compare.py 分歧點**：index=${IDX} @ T=${T}, golden=${GOLD}, actual=${ACT}

**📊 三大可能方向 + 概率**：
1. [高概率 ${P1}%] ${DIR1_NAME}：${DIR1_DESC}
   → 建議動作：${DIR1_ACTION}
2. [中概率 ${P2}%] ${DIR2_NAME}：${DIR2_DESC}
   → 建議動作：${DIR2_ACTION}
3. [低概率 ${P3}%] ${DIR3_NAME}：${DIR3_DESC}
   → 建議動作：${DIR3_ACTION}

**📎 佐證資料**：
- vcd.py value @ T=${T}..T+10：${VALUE_LOG}
- compare.py JSON：[attach]
- wave.svg 時序圖：[attach]
- sim_setting diff（如有）：[attach]

**📋 下一步**（請 DD/SD owner 確認）：
1. ${NEXT_STEP_1}
2. ${NEXT_STEP_2}

_概率總和 = ${P1 + P2 + P3}%（保留 ${100 - P1 - P2 - P3}% 給未預期錯誤）_
```

---

## 錯誤指紋速查表

| 觀察現象 | 優先懷疑 | 次級懷疑 |
|----------|----------|----------|
| compare divergence = constant offset | A (RTL) | C (config scale) |
| exp/act 波形一致但差 N cycle | **B (checker timing)** | A (pipeline) |
| x/z 出現在預期穩定訊號 | **A (RTL)** | — |
| ±1 LSB 誤差 | **D (fixed-point)** | A |
| 只在 first/last beat 失敗 | **B (checker boundary)** | — |
| 跨多個 checker 同時 fail | **D (C++)** / **C (config)** | — |
| FSM 進入非法狀態 | **A (RTL)** | — |
| 跨不同 config 皆 fail | **A (RTL)** | D (C++) |
| hex 數值有 scale factor 關係 | **C (config)** | — |
| VCD 數量級的 data 全對只有幾個點錯 | B (checker) | A (corner) |
| vcs.log 有 "sim_setting loaded: <path>" | **C (config path)** | — |

---

## Checker 四問驗證法（TXCMP / RXCMP）

對任何 failing checker，依序回答四個問題：

**Q1: Trigger 時機對嗎？**
```bash
# 檢查 checker 的 enable/trigger signal
python3 tools/vcd.py changes debug.vcd tb.TXCMP.enable $((T-100)) $((T+100))
# 如果 enable 在 T 時不在 1，表示比對時間窗沒涵蓋到錯誤點
```

**Q2: Expected 值對嗎？**
```bash
# 檢查 checker 從 hex 讀入的 expected value
python3 tools/vcd.py value debug.vcd tb.TXCMP.exp_data $T
python3 tools/vcd.py value debug.vcd tb.TXCMP.exp_data $((T-1))
# 如果 exp_data 本身就不合理，表示 phyUD hex load 有問題（Type C/D）
```

**Q3: Actual 值對嗎？**
```bash
# 直接從 RTL source 追 actual data 的來源
python3 tools/vcd.py value debug.vcd tb.dut.phyUD $T
# 如果 actual 跟 RTL behavior 一致 → checker 在報錯但 RTL 沒錯（Type B）
```

**Q4: Compare window 範圍對嗎？**
```bash
# 檢查 checker 的 compare window
python3 tools/vcd.py changes debug.vcd tb.TXCMP.compare_window $((T-100)) $((T+100))
# 如果 compare window 太窄 → 遺漏了部分 data（Type B）
```

### 常見 Checker Bug 5 種 Pattern

| Pattern | 診斷 | 解法 |
|---------|------|------|
| **Latency mismatch** | exp/act 形狀一致，差固定 cycle | 調整 checker 的 latency parameter |
| **Stale data** | checker 讀到上一筆 transaction 的值 | 檢查 compare window 邊界條件 |
| **Off-by-one** | exp/act 互相差 1 entry index | 調整 hex 載入的起始 offset |
| **Mask missing** | exp 有 x/z 但 checker 沒對應 mask | 增加 mask 條件 |
| **Double counting** | 同一筆資料被 checker 比對兩次 | 檢查 done/complete flag 的 deassert 時機 |

---

## sim_setting.json 差異比對演算法

```python
# compare_sim_settings.py — 兩份 json 的遞迴比對
def diff_json(ref, target, path=""):
    diffs = []
    for key in ref:
        full_path = f"{path}.{key}" if path else key
        if key not in target:
            diffs.append({"type": "missing", "path": full_path, "ref": ref[key]})
        elif type(ref[key]) != type(target[key]):
            diffs.append({"type": "type_mismatch", "path": full_path, "ref": type(ref[key]).__name__, "target": type(target[key]).__name__})
        elif isinstance(ref[key], dict):
            diffs += diff_json(ref[key], target[key], full_path)
        elif ref[key] != target[key]:
            diffs.append({"type": "value_diff", "path": full_path, "ref": ref[key], "target": target[key]})
    for key in target:
        if key not in ref:
            diffs.append({"type": "extra", "path": f"{path}.{key}" if path else key, "value": target[key]})
    return diffs

# 執行比對
diffs = diff_json(reference_settings, runtime_settings)
```

### 常見 Config 陷阱

| 參數 | 預期值 | 錯誤值範例 | 影響 |
|------|--------|-----------|------|
| `latency_mode` | `0` (low) | `1` (high) | phyUD 所有 hex 的 timing 錯位 |
| `freq_ratio` | `4` | `2` | data rate 差一倍 → compare 全錯 |
| `data_width` | `32` | `16` | phyUD dump 的 bit-width 不匹配 |
| `calibration_mode` | `auto` | `manual` | ZQ/DLL 收斂值不同 |
| `rounding` | `round_half_up` | `truncation` | ±1 LSB 誤差（常見！） |
| `saturation` | `saturate` | `wrap` | overflow 時數值完全不同 |
