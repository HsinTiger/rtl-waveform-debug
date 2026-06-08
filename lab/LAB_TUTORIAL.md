# Lab Tutorial — phyUD Debug Pipeline 實作練習

> **對象：** 工網內 Claude Code Agent（multi-agent 協作）
> **環境：** tcsh + Linux + Python 3.8+
> **前置：** 已有 buggy module testbench + RTL + phyUD hex dump（讀過 DEBUG_PLAYBOOK.md）
> **說明：** 以下每一步、每一條指令，Agent 應照做。完成後產出「三大方向 + 概率」報告。

---

## 目錄

- [Step 0: 環境確認](#step-0-環境確認)
- [Step 1: grep vcs.log 找第一個 Error](#step-1-grep-vcslog-找第一個-error)
- [Step 2: FSDB 時間切片 → VCD 轉檔](#step-2-fsdb-時間切片--vcd-轉檔)
- [Step 3: vcd.py 清點訊號](#step-3-vcdpy-清點訊號)
- [Step 4: vcd.py 查值 — 錯誤時間點附近](#step-4-vcdpy-查值--錯誤時間點附近)
- [Step 5: compare.py — 找 RTL vs Golden 分歧點](#step-5-comparepy--找-rtl-vs-golden-分歧點)
- [Step 6: cmodel_hex.py — 驗證 golden 格式](#step-6-cmodel_hexpy--驗證-golden-格式)
- [Step 7: WaveJSON + SVG 時序圖](#step-7-wavejson--svg-時序圖)
- [Step 8: Checker 四問驗證法](#step-8-checker-四問驗證法)
- [Step 9: sim_setting.json 差異比對](#step-9-sim_settingjson-差異比對)
- [Step 10: 綜合判斷 → 產出最終報告](#step-10-綜合判斷--產出最終報告)

---

## 準備：你要準備的檔案（由使用者預先準備）

在開始之前，使用者已準備好以下檔案：

```bash
# 你的檔案（實際路徑以使用者告知為準）
/proj/lab/vcs.log          # VCS 模擬 log（內含 UVM_ERROR）
/proj/lab/top.fsdb         # FSDB 波形（或用 $dumpvars 產生的 dump.vcd）
/proj/lab/output_data/phyUD.hex  # phyUD 平台 dump 的中間節點 hex
/proj/lab/rtl/phy_calc.sv        # RTL source（含 bug）
/proj/lab/tb/testbench.sv        # module testbench
/proj/lab/tb/TXCMP_calc_checker.sv  # TX checker
/proj/lab/sim/sim_setting.json   # 模擬設定
```

如果使用者尚未準備，可用 repo 中的 `lab/example/` 作為替代：

```bash
# 替代方案：使用 repo 內建的 example 檔案
export LAB_DIR=/path/to/rtl-waveform-debug/lab/example
ls $LAB_DIR/rtl/
ls $LAB_DIR/sim/
ls $LAB_DIR/golden/
```

---

## Step 0: 環境確認

**目標：** 確保所有工具和輸入檔案都在正確位置。

```bash
# 0.1 設定 repo 路徑
setenv RTLDBG /proj/eda/tools/rtl-waveform-debug

# 0.2 自我測試（預期 ALL PASS）
sh $RTLDBG/tools/_selftest.sh

# 0.3 確認 Verdi 可用（如果來源是 FSDB）
which fsdb2vcd

# 0.4 確認所有輸入檔案存在
ls -la /proj/lab/vcs.log /proj/lab/top.fsdb /proj/lab/output_data/phyUD.hex

# 0.5 使用 example 則改為
ls -la $LAB_DIR/sim/vcs.log $LAB_DIR/sim/dump_buggy.vcd $LAB_DIR/golden/phy_calc.hex
```

**驗收：** `_selftest.sh` 回傳 ALL PASS。所有輸入檔案存在。

---

## Step 1: grep vcs.log 找第一個 Error

**目標：** 從 vcs.log 中找出第一個 UVM_ERROR 發生的時間 `T` 與嫌疑訊號名。

```bash
# 1.1 grep UVM_ERROR（最常見）
grep -n "UVM_ERROR" /proj/lab/sim/vcs.log | head -10

# 1.2 grep assertion fail
grep -n -i "ASSERT\|FAIL\|MISMATCH" /proj/lab/sim/vcs.log | head -10

# 1.3 從 error 訊息萃取時間與訊號
# 預期輸出範例：
#   UVM_ERROR @ 30 ns:  TXCMP mismatch cycle=0 exp=0x003F got=0x003E
#   → T = 30ns, signal = TXCMP (tb.TXCMP)
```

**重點：** 記錄 `T`（第一個 error 的模擬時間），後續步驟會用到。

---

## Step 2: FSDB 時間切片 → VCD 轉檔

**目標：** 在錯誤時間 `T` 前後各取 100ns 做時間切片，減少 VCD 體積。切片要分兩段：先在 FSDB 域用 `fsdbextract` 切（資料仍是壓縮的），再把小 slice 用 `fsdb2vcd` 轉成 VCD（轉檔階段不帶任何切片參數）。

```bash
# 2.1 如果來源是 FSDB，先在 FSDB 域用 fsdbextract 做時間 + Scope 切片
#     -bt/-et 時間「必須帶單位」（ns），-s scope 用斜線分隔，-level 0 = scope 及其以下全部
set T=30        # ← 從 Step 1 取得的時間（ns）
set BT=`expr $T - 100`
set ET=`expr $T + 100`

sh $RTLDBG/tools/fsdbextract.sh /proj/lab/top.fsdb \
  -bt ${BT}ns -et ${ET}ns \
  -s /tb/dut -level 0 \
  -o /tmp/slice.fsdb +grid

# 2.2 把切好的小 slice 轉成 VCD（fsdb2vcd 不帶任何切片參數）
sh $RTLDBG/tools/fsdb2vcd.sh /tmp/slice.fsdb -o /tmp/debug.vcd

# 2.3 如果已有 VCD（如 $dumpvars 產生的），直接複製
cp /proj/lab/sim/dump_buggy.vcd /tmp/debug.vcd

# 2.4 確認 VCD 大小
ls -lh /tmp/debug.vcd

# 2.5 確認 timescale
head -3 /tmp/debug.vcd
```

**預期：** VCD 小於 10MB（有時間切片的話）。

---

## Step 3: vcd.py 清點訊號

**目標：** 確認 VCD 中所有訊號的 canonical full name。

```bash
# 3.1 列出所有訊號
python3 $RTLDBG/tools/vcd.py list /tmp/debug.vcd

# 3.2 搜尋關鍵訊號（注意：要使用 canonical full name）
python3 $RTLDBG/tools/vcd.py list /tmp/debug.vcd --match out_val
python3 $RTLDBG/tools/vcd.py list /tmp/debug.vcd --match TXCMP
python3 $RTLDBG/tools/vcd.py list /tmp/debug.vcd --match clk

# 3.3 記錄 canonical full name 供後續使用
# 範例：
#   tb.dut.out_val
#   tb.dut.clk
#   tb.TXCMP.error_flag
#   tb.dut.valid_out
```

**注意：** 之後所有查詢必須用 canonical full name（如 `tb.dut.out_val`），不要用短名。

---

## Step 4: vcd.py 查值

**目標：** 在錯誤時間 `T` 前後，看各訊號的值。

```bash
# 4.1 在 T 前後各查 5 個點
set T=30
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.out_val `expr $T - 10`
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.out_val $T
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.out_val `expr $T + 10`

# 4.2 看 checker signals
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.TXCMP.error_flag $T
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.TXCMP.exp_val $T
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.TXCMP.act_val $T

# 4.3 看 control signals
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.valid_in $T
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.valid_out $T

# 4.4 看變化（T 附近 50ns, 若 T=30）
python3 $RTLDBG/tools/vcd.py changes /tmp/debug.vcd tb.dut.out_val 10 50
python3 $RTLDBG/tools/vcd.py changes /tmp/debug.vcd tb.TXCMP.error_flag 10 50
```

**解讀：**

| 觀察 | 意思 |
|------|------|
| `exp_val` ≠ `act_val` | RTL 值與 phyUD golden 不一致 ← 正常，這就是 mismatch |
| `error_flag=1` | checker 已觸發 |
| `valid_out=1` 時 mismatch | 比對時機正確 |
| `valid_out=0` 時 mismatch | checker 可能在錯誤時間觸發（Type B） |

---

## Step 5: compare.py — 找 RTL vs Golden 分歧點

**目標：** 用確定性工具找出 RTL 與 phyUD golden hex 的第一個分歧。

```bash
# 5.1 基本用法（含 --skip-x 跳過 reset 期間的 x）
python3 $RTLDBG/tools/compare.py /tmp/debug.vcd \
  --clk tb.dut.clk \
  --sig tb.dut.out_val \
  /proj/lab/output_data/phyUD.hex --skip-x

# 5.2 如果 example 目錄
python3 $RTLDBG/tools/compare.py /tmp/debug.vcd \
  --clk tb.dut.clk \
  --sig tb.dut.out_val \
  $LAB_DIR/golden/phy_calc.hex --skip-x

# 5.3 如需指定時間範圍（避免取樣到邊界）
python3 $RTLDBG/tools/compare.py /tmp/debug.vcd \
  --clk tb.dut.clk \
  --sig tb.dut.out_val \
  /proj/lab/output_data/phyUD.hex --skip-x \
  --t0 10 --t1 200

# 5.4 如果 mismatch，試 --t0 微調對齊
# （C-model 可能比 RTL 早/晚幾個 cycle 開始）
python3 $RTLDBG/tools/compare.py /tmp/debug.vcd \
  --clk tb.dut.clk \
  --sig tb.dut.out_val \
  /proj/lab/output_data/phyUD.hex --skip-x \
  --t0 20
```

**預期輸出（正確 RTL）：**
```json
{ "signal": "tb.dut.out_val", "match": true, ... }
```

**預期輸出（buggy RTL）：**
```json
{
  "signal": "tb.dut.out_val",
  "match": false,
  "first_divergence": {
    "index": 0,
    "clk_time": 15,
    "golden": "3F",
    "actual": "3E"
  }
}
```

「index=0, golden=0x3F, actual=0x3E」表示：第 0 個 clk cycle（@15ns），RTL 輸出 0x3E，但 golden 期望 0x3F，差了 1 LSB。

---

## Step 6: cmodel_hex.py — 驗證 golden 格式

**目標：** 確認 phyUD hex dump 可以正確被載入。

```bash
# 6.1 載入並印出前 10 筆
python3 $RTLDBG/tools/cmodel_hex.py $LAB_DIR/golden/phy_calc.hex | head -10

# 6.2 如果 parse 失敗，檢查原始檔案格式
head -3 $LAB_DIR/golden/phy_calc.hex

# 6.3 如果格式不匹配，調整 cmodel_hex.py 中的 adapter
grep -n "IF AUTO-DETECT IS WRONG" $RTLDBG/tools/cmodel_hex.py
```

**格式支援：**
- 每行一個 hex（`A5`）
- 兩欄：`<idx> <hex>`（`0 A5`）
- 含 node 名：`<node> = <hex>`，需加 `--node` 參數
- 含 node+idx：`<node> <idx> <hex>`，需加 `--node`

---

## Step 7: WaveJSON + SVG 時序圖

**目標：** 將實際波形轉成 WaveJSON 並渲染成 SVG 圖片。

```bash
# 7.1 轉成 WaveJSON（在 T 前後各取 3 個 cycle）
python3 $RTLDBG/tools/vcd.py wavejson /tmp/debug.vcd \
  --clk tb.dut.clk \
  --sig tb.dut.out_val tb.dut.valid_in tb.dut.valid_out tb.TXCMP.error_flag \
  --t0 `expr $T - 15` --t1 `expr $T + 15` > /tmp/wave.json5

# 7.2 檢查 JSON 格式
cat /tmp/wave.json5

# 7.3 渲染成 SVG
sh $RTLDBG/tools/render_wavedrom.sh /tmp/wave.json5 /tmp/wave.svg

# 7.4 確認 SVG 有內容
ls -lh /tmp/wave.svg
```

---

## Step 8: Checker 四問驗證法

**目標：** 用四問法驗證 TXCMP/RXCMP checker 的正確性。

```bash
# Q1: Trigger 時機對嗎？
# 檢查 checker 的 enable / 觸發條件
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.valid_out `expr $T - 5`
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.valid_out $T

# Q2: Expected 值對嗎？
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.TXCMP.exp_val $T
# 跟 phyUD hex 手動交叉比對

# Q3: Actual 值對嗎？
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.TXCMP.act_val $T
# 跟 tb.dut.out_val 比對——兩者應該一致
python3 $RTLDBG/tools/vcd.py value /tmp/debug.vcd tb.dut.out_val $T

# Q4: Compare window 對嗎？
# 看 checker 是否只在 valid_out=1 時比對
python3 $RTLDBG/tools/vcd.py changes /tmp/debug.vcd tb.dut.valid_out 0 200
```

**判斷標準：**

| 結果 | 推測 |
|------|------|
| exp/act 值不同 + 形狀一致但差 N cycle | **Type B: Checker timing**—latency parameter 設錯 |
| exp/act 值 ±1 LSB 誤差 | **Type D: Fixed-point** 或 **Type A: RTL truncation** |
| exp 值本身就是錯的 | **Type C: Config error** 或 **Type D: C++ bug** |
| RTL output 值與 spec 一致但與 exp 不同 | **Type D: phyUD C++ bug** |

---

## Step 9: sim_setting.json 差異比對

**目標：** 如果懷疑 sim_setting 有問題，比對 runtime 使用的 json 與 reference。

```bash
# 9.1 從 vcs.log 中找出 sim_setting 路徑
grep "sim_setting" /proj/lab/sim/vcs.log

# 9.2 拿到 reference json（跟 DD 要，或從 git 取得）
# 9.3 比對兩份 json
diff /proj/lab/sim/sim_setting.json /path/to/reference/sim_setting.json

# 9.4 如果只有一份，檢查關鍵參數
python3 -c "
import json
with open('/proj/lab/sim/sim_setting.json') as f:
    cfg = json.load(f)
params = cfg['phy_calc']['parameters']
print(f'gain={params[\"gain\"]}, shift={params[\"shift_bits\"]}, offset={params[\"offset\"]}')
print(f'round_mode={params[\"round_mode\"]}')
"
```

**常見 config 陷阱：**

| 參數 | 正常值 | 錯誤值 | 影響 |
|------|--------|--------|------|
| `gain` | 5 | 16 | 所有輸出放大 3.2x |
| `round_mode` | `round_to_nearest` | `truncation` | ±1 LSB |
| `shift_bits` | 3 | 其他 | 精度錯位 |

---

## Step 10: 綜合判斷 → 產出最終報告

**目標：** 綜合前 9 步的證據，產出「三大可能方向 + 概率」的結構化報告。

### 決策流程

```python
# 偽代碼：Agent 的決策邏輯
if sim_setting_diff != empty:
    方向1 = ("Config mismatch", 60%)
    方向2 = ("RTL behavior", 25%)
    方向3 = ("Checker timing", 15%)
elif checker_timing_wrong:
    方向1 = ("Checker timing", 55%)
    方向2 = ("RTL behavior", 30%)
    方向3 = ("Config/C++", 15%)
elif compare_divergence == "±1 LSB":
    方向1 = ("RTL truncation (Type A)", 45%)
    方向2 = ("C++ fixed-point (Type D)", 35%)
    方向3 = ("Config precision mismatch", 20%)
elif compare_divergence == "multiple bit / constant offset":
    方向1 = ("RTL behavior (Type A)", 60%)
    方向2 = ("C++ behavioral (Type D)", 25%)
    方向3 = ("Config parameter (Type C)", 15%)
else:
    方向1 = ("RTL behavior (Type A)", 45%)
    方向2 = ("Checker (Type B)", 30%)
    方向3 = ("Config (Type C)", 15%)
    # 保留 10% 給未預期錯誤 (Type D or unknown)
```

### 輸出格式模板

```markdown
---
**🕐 錯誤時間定位**：T = 30ns，signal = tb.dut.out_val

**🔍 compare.py 分歧點**：
- index=0, clk_time=15ns, golden=0x3F, actual=0x3E
- mismatch type: ±1 LSB (truncation vs rounding)

**📊 三大可能方向 + 概率分布**：

1. **[高概率 45%] RTL behavior — truncation instead of rounding**
   - 證據：compare.py 顯示 ±1 LSB 誤差，實際值總是比 golden 小 1
   - 建議動作：檢查 RTL phy_calc.sv 第 15 行，確認 `>> shift` 前有無加 round_bit
   - vcd.py value evidence: @15ns out_val=0x3E vs exp_val=0x3F

2. **[中概率 30%] Checker (TXCMP) timing**
   - 證據：exp/act 形狀一致但始終差 1
   - 建議動作：檢查 TXCMP 的 latency_cycles 參數是否為 2

3. **[低概率 15%] sim_setting.json config**
   - 證據：確認 round_mode 是否為 round_to_nearest
   - 建議動作：`diff` 兩份 json 確認

**📎 佐證資料**：
- vcd.py value @ T=15..45：已隨附
- compare.py JSON：[attach]
- /tmp/wave.svg 時序圖：[attach]
- sim_setting 參數摘要：[attach]

**📋 下一步（請 DD/SD owner 確認）**：
1. 檢查 RTL phy_calc.sv line 15-18：是否有 round_bit addition？
2. 與 SD 確認 phyUD C++ 使用的 rounding mode
3. 重新跑 sim_setting.json 正確版本的 regression

_概率總和 = 90%（保留 10% 給未預期錯誤）_
```

### 產出最終報告

```bash
# 將上述結果寫入檔案
cat > /tmp/debug_report.md << 'REPORT_EOF'
# (貼上最終報告內容)
REPORT_EOF

echo "✅ Debug report written to /tmp/debug_report.md"
```

---

## 驗收標準

| Step | 驗收項 | Pass |
|------|--------|------|
| 0 | `_selftest.sh` ALL PASS | ⬜ |
| 1 | 從 vcs.log 萃取出 T 與嫌疑訊號 | ⬜ |
| 2 | VCD 可被 vcd.py 讀取（list 回傳訊號） | ⬜ |
| 3 | 所有訊號名用 canonical full name | ⬜ |
| 4 | Step 4 的 value/changes 回傳非空結果 | ⬜ |
| 5 | compare.py 找出分歧點（或不匹配時 rc=3） | ⬜ |
| 6 | cmodel_hex.py 正確解析 hex | ⬜ |
| 7 | wave.svg 可開、看得到波形 | ⬜ |
| 8 | Checker 四問皆回答 | ⬜ |
| 9 | sim_setting 參數確認 | ⬜ |
| 10 | 最終報告包含三大方向+概率 | ⬜ |

---

## 常見問題

**Q: vcd.py 說 signal not found？**
A: 先用 `vcd.py list --match <name>` 看真正的 canonical full name 是什麼。不要用短名。

**Q: compare.py 回傳 actual_samples=0？**
A: 可能所有 out_val 都是 x。檢查 `--skip-x` 是否跳過了所有 sample，或檢查 VCD 中 out_val 的變化。

**Q: vcs.log 沒有 UVM_ERROR？**
A: grep `*E,` 或 `ASSERT` 或 `FAIL`。如果再沒有，問使用者哪個 testcase 失敗。

**Q: 有多個 UVM_ERROR？**
A: 只看「第一個」error。後續 error 通常是連鎖反應。
