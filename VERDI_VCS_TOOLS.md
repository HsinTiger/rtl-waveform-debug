# Verdi / VCS 工具鏈 — LLM Agent 可用功能

> **環境：** 工網內有 Verdi + VCS EDA license
> **目標：** 找出可被 script/命令列呼叫、產出文字/結構化結果、讓 LLM Agent 理解 RTL 結構與時序的工具

---

## 1. Verdi KDB（Knowledge Database）⭐ 核心推薦

### KDB 是什麼

KDB 是 Verdi 在 compile RTL 時建立的結構化資料庫，包含：
- 完整的 **module hierarchy**（誰 instantiate 誰）
- 每個 module 的 **port / signal / parameter 宣告**
- **Signal connection**（哪個 signal 接到哪個 module 的哪個 port）
- **FSM state encoding**（state machine 的 state name 與 binary encoding）
- **Instance path**（從 top 到每個 leaf cell 的完整路徑）

### 命令列工具

```bash
# 建立 KDB（在 compile flow 中加入）
vcs -debug_access+all -kdb ...
# 或在已編譯好的 simv 目錄中
verdi -kdb -dir simv.daidir/kdb.elab++

# KDB 查詢（無需開 GUI）
# 列出所有 module
verdi -kdb -dir <kdb_dir> -c -batch "list_module"

# 查詢特定 module 的 port 列表
verdi -kdb -dir <kdb_dir> -c -batch "get_ports tb.dut.phy_ud"

# 查詢 signal 的 driver
verdi -kdb -dir <kdb_dir> -c -batch "get_drivers tb.dut.phy_ud.rx_data"

# 查詢 signal 的 load（fan-out）
verdi -kdb -dir <kdb_dir> -c -batch "get_loads tb.dut.phy_ud.tx_valid"

# 查詢 FSM state encoding
verdi -kdb -dir <kdb_dir> -c -batch "fsm_list tb.dut.ctrl"
verdi -kdb -dir <kdb_dir> -c -batch "fsm_state tb.dut.ctrl.fsm_state"
```

### LLM Agent 能利用 KDB 做什麼

1. **訊號溯源**：當 LLM 想知道「這個 signal 是從哪個 module 的哪個 output 來的」，可以用 `get_drivers` 拿到驅動源 → 不需要人告訴它
2. **Scope 路徑驗證**：用 `list_module` 確認 hierarchy 是否跟 `vcd.py list` 的結果一致
3. **FSM trace**：當 debug 到 control path 問題時，用 `fsm_list` 看 state machine 的編碼與轉換
4. **Cross-module 連線追蹤**：用 `get_ports` / `get_loads` 追蹤跨 module 的 data path

### 與 vcd.py 的整合方式

```
KDB（static design structure） +  VCD（dynamic simulation values） = 完整理解
  ├─ 知道 signal 從哪來          ├─ 知道 signal 值是什麼
  ├─ 知道 FSM state encoding     ├─ 知道 FSM state 跳轉時間
  └─ 知道 hierarchy path          └─ 知道 value at specific time
```

Agent 的 debug 流程：
1. `vcd.py` 找到有問題的 signal 與時間
2. `KDB get_drivers` 追到該 signal 的驅動 source module
3. 讀取對應的 RTL source file，檢查 always/assign 的正確性

---

## 2. nTrace 命令列 / Tcl 模式

### 可用功能

```bash
# nTrace batch mode — 載入 KDB 後執行 Tcl script
verdi -dbg -ssf top.fsdb -ssw top.ssw -tcl cause.tcl

# 常用 Tcl 命令
# 列出 scope hierarchy
get_design_scope -module tb.dut.phy_ud

# 列出 scope 內所有 signal
get_signals -scope tb.dut.phy_ud

# 查找 signal 定義位置
search_signal -name rx_data -scope tb.dut.phy_ud

# 顯示 signal 的驅動邏輯
trace_driver -signal tb.dut.phy_ud.rx_data

# 列出 FSM
fsm_list -scope tb.dut.ctrl
fsm_state -signal tb.dut.ctrl.fsm_state -encoding binary
```

### 輸出格式

nTrace 命令列輸出是**純文字**，可直接被 Agent 解析，例如：
```
Module: tb.dut.phy_ud
Ports:
  rx_data[31:0] (input)
  tx_data[31:0] (output)
  rx_valid (input)
  tx_valid (output)
  clk (input)
  rst_n (input)
```

---

## 3. nWave 命令列 / Tcl 模式

### Signal Query（比對 vcd.py 的結果）

```bash
# nWave batch mode — 不開 GUI 查 signal value
verdi -dbg -ssf top.fsdb -ssw top.ssw -tcl query.tcl

# Tcl script 內容（query.tcl）：
#   open_waveform top.fsdb
#   get_signal_value tb.dut.phy_ud.rx_data -time 1525
#   get_signal_value tb.dut.phy_ud.rx_valid -time 1525
#   get_signal_transitions tb.dut.phy_ud.rx_data -from 1500 -to 1600

# 自動截圖 — 給 demo PPT 用
#   set_cursor -time 1525
#   zoom_range -from 1480 -to 1580
#   add_wave {tb.clk tb.dut.phy_ud.rx_data tb.TXCMP.exp_data tb.TXCMP.act_data}
#   screenshot -file wave_screenshot.png
```

### 與 vcd.py 的比較

| 功能 | vcd.py | nWave Tcl | 建議 |
|------|--------|-----------|------|
| Signal value 查詢 | ✅ 快速，純文字 | ✅ 但需開 KDB | 日常 debug 用 vcd.py |
| Time range query | ✅ --t0/--t1 | ✅ get_signal_transitions | 日常 debug 用 vcd.py |
| 波形截圖 | ❌（需 render_wavedrom） | ✅ screenshot | **Demo PPT 用 nWave** |
| 大 FSDB 解析 | ❌ 不直接讀 FSDB | ✅ 原生支援 FSDB | 大檔案優先 nWave |
| Hierarchy 瀏覽 | ❌ 只有 flat list | ✅ 保留 scope 結構 | 結構查詢用 nWave |

---

## 4. VCS Dump 選項（零 Verdi 授權方案）

### $dumpvars 語法（testbench 中加入）

```verilog
initial begin
  $dumpfile("dump.vcd");
  $dumpvars(0, tb);                    // dump tb 層級以下所有訊號
  // 或指定 scope
  $dumpvars(0, tb.dut.phy_ud);        // 只 dump phy_ud module
  $dumpvars(0, tb.TXCMP);             // 同時也 dump checker
  $dumpvars(1, tb.dut.mem_array);     // level=1 只 dump 一層，不遞迴
end
```

### 命令列選項（不修改 testbench）

```bash
# VCS 命令列加入（不需改 Verilog code）
./simv +vcd+file=dump.vcd +vcd+scope=tb.dut.phy_ud
./simv +vcd+file=dump.vcd +vcd+scope=tb.TXCMP

# 指定 multi-scope
./simv +vcd+file=dump.vcd \
  +vcd+scope=tb.dut.phy_ud \
  +vcd+scope=tb.TXCMP

# 限制時間範圍（節省 VCD 體積）
./simv +vcd+file=dump.vcd \
  +vcd+dumpstart=1000 \
  +vcd+dumpend=5000
```

### VCS Assertion Dump

```bash
# 啟用 assertion 監控（vcs.log 會出現更多結構化資訊）
./simv -assert dumpoff+assert \
  +vcd+file=assert.vcd \
  +vcd+scope=tb.TXCMP
```

---

## 5. VCS Compile-Time 選項

### Design Structure Dump

```bash
# 編譯時輸出 hierarchy
vcs -debug_access+all -kdb ...
# 產生 simv.daidir/kdb.elab++ 目錄 → 被 Verdi KDB 使用

# 直接在 compile log 中列出所有 module
vcs -l ca.log -debug_access+all -kdb ...
grep "Module:" ca.log | sort -u
```

### Assertion Control

```bash
# 編譯時啟用 assertion
vcs -assert enable_diag \
    -assert svaext \
    +define+ASSERT_ON

# 模擬時指定 assertion 輸出
./simv -assert report=assert.rpt \
       -assert verbose=3 \
       -assert filter=stop
```

### Coverage Options

```bash
# 啟用 coverage dump
vcs -cm line+tgl+assert -cm_name test1 ...
./simv -cm assert+line

# 產出 coverage report（文字格式，agent 可讀）
urg -dir simv.vdb -report coverage.rpt -format text
```

---

## 6. fsdb2vcd -l — Scope 列表

這個常常被忽略但**非常有用**：

```bash
# 列出 FSDB 中的所有 scope（不開 Verdi GUI）
fsdb2vcd -l top.fsdb

# 預期輸出（純文字）：
# Scope tree:
#   tb
#     clk
#     rst_n
#     dut
#       phy_ud
#         rx_data[31:0]
#         tx_data[31:0]
#         rx_valid
#         tx_valid
#         ...
#     TXCMP
#       enable
#       exp_data[31:0]
#       act_data[31:0]
#       ...
```

Agent 可以用這個來：
1. 在 `fsdbextract` 的 `-s` 參數中填入正確的 scope path（slash 形式，如 `/tb/dut`，避免拼錯）
2. 快速決定哪些 scope 要包含在 time/scope slice 中（slicing 用 `fsdbextract`，見下方第 7 節）
3. 比對 vcs.log 中的訊號名是否與 FSDB 中的 scope path 一致

---

## 7. fsdbextract — FSDB 域切片（time / scope slicing）

> **重點：** `fsdb2vcd` 不做切片。切片要先用獨立工具 **fsdbextract**（FSDB→FSDB，資料維持壓縮），再把小檔轉成 VCD。

```bash
# Stage 1：在 FSDB 域切片（time + scope），資料不解壓
sh $RTLDBG/tools/fsdbextract.sh top.fsdb -bt 100ns -et 200ns -s /tb/dut -level 0 -o slice.fsdb +grid

# Stage 2：把小 slice 轉成 VCD（fsdb2vcd 不帶任何切片 flag）
sh $RTLDBG/tools/fsdb2vcd.sh slice.fsdb -o slice.vcd

# Stage 3：工具層細切（vcd.py / compare.py 的 --t0/--t1，不變）
python3 $RTLDBG/tools/compare.py slice.vcd --clk ... --sig ... golden.hex --t0 N --t1 N
```

### fsdbextract 選項（依 Realtek Verdi FAQ「FsdbExtraction」）

| 選項 | 說明 |
|------|------|
| `-bt <time><unit>` | begin time，**單位必填**，如 `-bt 100ns`（不可寫成去單位的 `100`） |
| `-et <time><unit>` | end time，如 `-et 200ns` |
| `-time_shift <t><u>` | 平移時間軸，如 `-time_shift -100ns`（向左 100ns） |
| `-s <hier>` | scope，**slash 分隔**：`/tb/dut`（不可用點號 `tb.dut`） |
| `-level 0\|1\|2` | **必須緊接在 `-s` 之後**。0=該 scope 及以下全部；1=僅該 scope 內（預設）；2=該 scope 加下一層 |
| `-o <out.fsdb>` | 輸出 FSDB |
| `+grid` | 丟到 grid 上跑（建議） |

> 路徑含特殊字元（如 `u1[0]`）：每個特殊字元前加 **7 個反斜線**，並用跳脫引號包住整個路徑。

---

## 推薦使用策略

### 日常 Debug（Agent 自動化）

```
VCD available (from $dumpvars or fsdb2vcd)
  ├─ vcd.py list / value / changes / wavejson → 確定性查詢
  ├─ compare.py → 找分歧點
  └─ render_wavedrom.sh → 產時序圖 SVG
```

### 大 FSDB / 需要結構查詢

```
FSDB only, no VCD
  ├─ fsdb2vcd -l → scope 列表
  ├─ fsdbextract → 先在 FSDB 域切片（time/scope），再 fsdb2vcd 轉小 VCD
  ├─ nWave Tcl → signal value 查詢（原生 FSDB 不轉 VCD）
  └─ Verdi KDB → design hierarchy / FSM / connection 查詢
```

### Demo PPT 製作

```
nWave Tcl
  └─ screenshot → 波形截圖放到 PPT
```

---

## 摘要：對 Agent 最有價值的工具

| 工具 | 輸出格式 | 價值 | 相依性 |
|------|----------|------|--------|
| **Verdi KDB** `get_drivers` / `fsm_list` | 純文字 | 🔴 理解電路結構與時序 | Verdi license |
| **fsdb2vcd -l** | 純文字 hierarchy | 🟡 快速看 scope 結構 | Verdi license |
| **nWave Tcl** | 純文字 / PNG | 🟡 大 FSDB 查詢 + 截圖 | Verdi license |
| **VCS +vcd+file** | VCD 檔 | 🟢 零授權成本 | VCS license |
| **VCS assertion report** | 純文字 | 🟢 assertion 結果 | VCS license |
