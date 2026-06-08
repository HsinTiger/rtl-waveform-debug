# 明天到公司 Checklist

> **日期：** 2026-06-08（一）
> **目標：** 把整包丟進工網 → 讓 Agent 照 LAB_TUTORIAL.md 跑完 → 驗收通過

---

## 早餐前（30 min）— 下載 + 丟進工網

```bash
# ① 在有外網的機器上 clone repo
git clone https://github.com/HsinTiger/rtl-waveform-debug.git

# ② 進目錄
cd rtl-waveform-debug

# ③ 自我測試（確認工具鏈在本機可跑）
sh tools/_selftest.sh
# 預期：6 項 ALL PASS
```

---

## 上午（2-3 hr）— 整包搬進工網 + smoke test

```bash
# ④ 上傳到工網機器
scp -r rtl-waveform-debug <工網機器>:/proj/eda/tools/

# ⑤ SSH 進工網機器
ssh <工網機器>

# ⑥ 放固定路徑
mkdir -p /proj/eda/tools/rtl-waveform-debug
cp -r rtl-waveform-debug/* /proj/eda/tools/rtl-waveform-debug/
cd /proj/eda/tools/rtl-waveform-debug

# ⑦ 工網內 smoke test
sh tools/_selftest.sh
# 如果 Python 版本不同 → 沒問題，vcd.py/compare.py 只靠 stdlib
# 如果 Verdi 路徑不同 → 先跑 module load verdi，或略過 fsdb2vcd（先用 example 的 VCD）
```

---

## 上午（1 hr）— 用 example 跑完整 pipeline

```bash
# ⑧ 設定 repo 路徑
setenv RTLDBG /proj/eda/tools/rtl-waveform-debug

# ⑨ 用內建 buggy VCD + golden hex 跑一次
# Step 5: compare.py 找分歧
python3 $RTLDBG/tools/compare.py \
  $RTLDBG/lab/example/sim/dump_buggy.vcd \
  --clk tb.dut.clk \
  --sig tb.dut.out_val \
  $RTLDBG/lab/example/golden/phy_calc.hex \
  --skip-x

# 預期輸出（rc=3）：
# { "first_divergence": { "index":0, "golden":"3F", "actual":"3E" } }

# ⑩ 驗證正確版 VCD 零分歧
python3 $RTLDBG/tools/compare.py \
  $RTLDBG/lab/example/sim/dump_correct.vcd \
  --clk tb.dut.clk \
  --sig tb.dut.out_val \
  $RTLDBG/lab/example/golden/phy_calc.hex \
  --skip-x

# 預期輸出（rc=0）：{ "match": true }
```

---

## 中午前（1 hr）— 放進你的真實 buggy case

```bash
# ⑪ 替換成你的檔案
#   vcs.log    → /proj/lab/regression/vcs.log
#   fsdb       → /proj/lab/regression/top.fsdb
#   phyUD.hex  → /proj/lab/output_data/phyUD.hex
#   RTL        → /proj/lab/rtl/
#   tb/checker → /proj/lab/tb/
#   sim_setting → /proj/lab/sim/sim_setting.json

# 如果來源是 FSDB（需要 Verdi license）：
fsdb2vcd -l /proj/lab/regression/top.fsdb | head -30  # 看 scope 結構

# 先在 FSDB 域用 fsdbextract 切片（資料維持壓縮）：
sh $RTLDBG/tools/fsdbextract.sh /proj/lab/regression/top.fsdb \
  -bt 2000ns -et 5000ns \
  -s /tb/dut -level 0 \
  -o /tmp/slice.fsdb +grid

# 再把小切片轉成 VCD（不帶切片旗標）：
sh $RTLDBG/tools/fsdb2vcd.sh /tmp/slice.fsdb -o /tmp/debug.vcd

# 如果來源是 VCD（直接用）：
cp /proj/lab/regression/dump.vcd /tmp/debug.vcd
```

---

## 下午（2 hr）— 跑 LAB_TUTORIAL.md 完整 10 步

```bash
# ⑫ 讓 Agent 執行（或自己照做）
# 打開 LAB_TUTORIAL.md 跟著做 Step 0 → Step 10
```

| Step | 動作 | 預期結果 | 打勾 |
|------|------|----------|------|
| 0 | `_selftest.sh` | ALL PASS | ⬜ |
| 1 | `grep UVM_ERROR vcs.log` | 取得時間 T 與訊號 | ⬜ |
| 2 | FSDB→VCD 或直接用 VCD | VCD 可讀 | ⬜ |
| 3 | `vcd.py list —match` | Canonical full name | ⬜ |
| 4 | `vcd.py value/changes` | 非空結果 | ⬜ |
| 5 | `compare.py --skip-x` | 分歧點 JSON | ⬜ |
| 6 | `cmodel_hex.py` | 正確 parse | ⬜ |
| 7 | `vcd.py wavejson → SVG` | 看得到波形 | ⬜ |
| 8 | Checker 四問 | 四問皆回答 | ⬜ |
| 9 | sim_setting 確認 | 參數正確 | ⬜ |
| 10 | 產出 debug_report.md | 三大方向+概率 | ⬜ |

---

## 下班前（1 hr）— 檢查清單

```markdown
## ✅ 通過條件

- [ ] `sh tools/_selftest.sh` → ALL PASS 通過
- [ ] `compare.py example/dump_correct.vcd` → match=true
- [ ] `compare.py example/dump_buggy.vcd` → mismatch（3F vs 3E）
- [ ] 你的真實 case 也跑出 compare.py 分歧點
- [ ] LAB_TUTORIAL.md Step 0–10 全部走完無卡關
- [ ] 最終 debug_report.md 已產出
- [ ] 三大方向 + 概率已寫在報告中
```

---

## 如果卡住

| 卡住點 | 解法 |
|--------|------|
| `_selftest.sh` FAIL | 檢查 Python 版本（≥ 3.8） |
| `fsdb2vcd` not found | `module load verdi` 或改用 example 的 VCD（不需要 Verdi） |
| `compare.py actual_samples=0` | 檢查 clk path 是否正確（`vcd.py list —match clk`） |
| `compare.py` 全部 mismatch | 試 `--t0 20` 跳過初始 x |
| 找不到 bug | 先用 example 確定工具鏈正確，再換你的 case |
| 你的 case 沒有 golden hex | 只剩 vcs.log + VCD（走無 golden 路徑，見 DEBUG_PLAYBOOK.md） |
