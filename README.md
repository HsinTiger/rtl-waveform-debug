# RTL ↔ 波形 協同 + DeepSeek Debug

讓**離線自架的 DeepSeek**，在 RTL designer 寫 code 的同時用**時序圖（WaveDrom）**跟人對齊意圖、
並在 VCS 模擬失敗時做事後 debug。波形是「人看的圖」也是「餵回模型的精確規格」。

## 兩條迴圈

**① 設計協同迴圈（主軸，純文字、不碰 FSDB）**
工程師白話文 → LLM 轉成 WaveJSON → 渲染給人確認「我理解成這樣對嗎」→ 同一份餵回模型 → 改 RTL。
WaveJSON 當共同語言，把白話文的歧義收斂掉。詳見 [`examples/round_trip_example.md`](./examples/round_trip_example.md)。

**② 事後 debug 迴圈（連 VCS 模擬驗證）**
VCS 跑掛 → VCD（native `$dumpvars`，或 FSDB 經 `fsdb2vcd`）+ vcs.log → 確定性工具把實際波形轉 WaveJSON →
`diff_waves(intended, actual)` 定位第一個分歧 → LLM 解釋成因、改 RTL。

## 關鍵事實（澄清「IEEE 都看得懂」的迷思）

- **VCD** ✅ IEEE 1364 純 ASCII，LLM 直接讀。
- **vcs.log** ✅ 純文字。
- **FSDB** ❌ Synopsys 專有二進位、無公開規格、無獨立開源 reader——**LLM 不能直接看**，要先 `fsdb2vcd`（Verdi 授權）。
- **「要 VCD 給工程師看」其實不必碰 FSDB**：Verilog 內建 `$dumpvars` 直接從模擬產 VCD，零 Verdi。
- **DeepSeek 主線純文字無 vision**：時序圖是「生成 WaveJSON 文字 → 渲染」，不是「看圖」。

## 交接整包（丟進工網用）

| 檔案 | 內容 |
|------|------|
| [`TOMORROW_RUNBOOK.md`](./TOMORROW_RUNBOOK.md) | **明天照做**：tcsh 具體步驟、實驗對象選法、把你的 FSDB 轉出來餵 agent、agent 怎麼看出問題 |
| [`HANDOFF_PLAN.md`](./HANDOFF_PLAN.md) | **交接計畫**：四種輸入對應、目錄結構、staging、Claude Code+tcsh bring-up、實測表、上線檢查表 |
| [`skill/SKILL.md`](./skill/SKILL.md) | **給 agent 的 skill**（Claude Code frontmatter）：兩條迴圈流程 + 工具用法 + 抗幻覺硬規則 |
| `tools/` | 確定性工具（純 Python stdlib，離線、**已實測**）：`vcd.py` / `cmodel_hex.py` / `compare.py` / `fsdb2vcd.sh` / `render_wavedrom.sh` / `_selftest.sh` |
| [`examples/round_trip_example.md`](./examples/round_trip_example.md) | 具體走一遍 round-trip（含 RTL、WaveJSON、白話文修改、diff 驗證） |

## 背景文件

| 檔案 | 內容 |
|------|------|
| [`EVALUATION.md`](./EVALUATION.md) | 主研究報告（格式、工具鏈、DeepSeek 能力、業界先例、部署、驗證），逐條附引用與信心等級 |
| [`DEPLOYMENT_GUIDE.md`](./DEPLOYMENT_GUIDE.md) | **大規模部署指南**：VCD 肥大、授權瓶頸、幻覺管控、團隊採用等 10 大問題與實戰解法 |
| [`SKILL_DRAFT.md`](./SKILL_DRAFT.md) | skill 的早期草稿（保留；正式版見 `skill/SKILL.md`） |
| [`VALUE_FOR_DESIGNERS.md`](./VALUE_FOR_DESIGNERS.md) | 對 RTL designer 的價值與「放大非取代」導入策略 |
| [`DEBUG_PLAYBOOK.md`](./DEBUG_PLAYBOOK.md) | **Agent Debug Playbook**：8 步 SOP + 四種錯誤指紋識別表 + Checker 四問驗證法 |
| [`VERDI_VCS_TOOLS.md`](./VERDI_VCS_TOOLS.md) | **Verdi/VCS 工具鏈**：KDB / nTrace 命令列工具，讓 Agent 理解 RTL 結構與時序 |
| [`DEMO_PLAN.html`](./DEMO_PLAN.html) | **3 天上線 Demo 計劃**：從環境打通到 6 頁 PPT 的完整互動路徑 |
| [`lab/LAB_TUTORIAL.md`](./lab/LAB_TUTORIAL.md) | **工網 Agent 實作教程**：10 步驟 SOP + 預先準備的 buggy RTL/hex/VCD——Agent 讀完後自動執行 |
| [`rtl-waveform-debug-lab.tar.gz`](./rtl-waveform-debug-lab.tar.gz) | **氣隙部署包**（39KB）：`tar xzf` 即可用。含全部 tools + docs + example 實驗資料 |

## 🆕 本次更新重點

### 1. fsdb2vcd 時間與訊號切片

`tools/fsdb2vcd.sh` 現在支援：

| 功能 | 指令 |
|------|------|
| 時間切片（1500ns～2500ns） | `fsdb2vcd.sh input.fsdb -o slice.vcd --bt 1500 --et 2500` |
| Scope 過濾 | `fsdb2vcd.sh input.fsdb --scope tb.dut.phy_ud` |
| 時間 + Scope 合併 | `fsdb2vcd.sh input.fsdb --bt 2850 --et 3150 --scope tb.dut.phy_ud` |
| 向後相容 | `fsdb2vcd.sh input.fsdb output.vcd`（與舊版完全相容） |
| 自動偵測 fsdb2vcd_fast | 若環境只有 GTKWave fast 版，跳警告且不傳不支援的選項 |
| 單位容錯 | `--bt 100ns` 自動去掉後綴當 `--bt 100` 處理 |

### 2. vcd.py 時間視窗過濾（即使用整份 VCD 也能切）

即使 fsdb2vcd 沒有加時間切片，轉出來的整份 VCD 仍然可以透過以下工具層的 `--t0`/`--t1` 做時間視窗：

```bash
python3 tools/vcd.py wavejson dump.vcd --clk clk --sig data --t0 2850 --t1 3150
python3 tools/compare.py dump.vcd --clk clk --sig data golden.hex --t0 2850 --t1 3150
```

**兩層切片策略：**
1. fsdb2vcd 粗切（裁掉 99% 的無關時間，減少 VCD 體積）
2. vcd.py/compare.py 細切（同一個粗 VCD 上快速切不同子視窗）

### 3. 大規模部署指南

參見 [`DEPLOYMENT_GUIDE.md`](./DEPLOYMENT_GUIDE.md) — 涵蓋 VCD 肥大、授權瓶頸、LLM 幻覺管控、團隊採用等 10 大問題與解法。

---

確定性工具（已驗證）

```sh
sh tools/_selftest.sh                                    # 全套 smoke test（6 項，ALL PASS）
python3 tools/vcd.py list dump.vcd                       # 列訊號
python3 tools/vcd.py value dump.vcd <sig> <time>         # 查某時刻值
python3 tools/vcd.py wavejson dump.vcd --clk clk --sig a b --t0 N --t1 N  # 時間視窗轉 WaveJSON
python3 tools/compare.py dump.vcd --clk clk --sig <node> golden.hex --skip-x --t0 N --t1 N   # 指定時間視窗比對
```
工具負責「值是什麼、哪裡分歧」（確定性），LLM 只負責「為什麼、怎麼改」——這是抗幻覺的核心分工。

## 工具問題速答

- 轉 VCD 的指令是 **`fsdb2vcd`（Verdi 工具，不是 vcs）**；用 `which fsdb2vcd` 確認你環境有沒有裝。
- **時間切片用法**：`tools/fsdb2vcd.sh input.fsdb --bt 1500 --et 2500 -o slice.vcd`（時間單位 = FSDB timescale，通常是 ns）。
- 但多數情況**直接 `$dumpvars` 產 VCD 更簡單**，FSDB 只在你們已習慣 dump FSDB 時才需要轉。

- ⚠️ 解 FSDB 需 **Verdi 授權**（VCD/log 不需）。
- ⚠️ DeepSeek 無 vision：時序圖＝生成文字再渲染。
- ⚠️ 數條 V4 規格來自次級來源（官方頁 403），上線前依 `EVALUATION.md` §10 覆核。
