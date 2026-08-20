---
id: F006
type: feature
title: oop-load-smoke
description: 純 C 程式跨進程載入共享函式庫，驗證生命週期與執行期契約
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: [F001, F003]
related-adr: [ADR-022, ADR-021]
related-feature: []
---

# F006: out-of-process 載入煙霧測試

## 功能概述

**要解決的問題**：這個專案從來沒有載入過它自己產出的共享函式庫。in-process 的 FFI 測試（`FFILifecycleSpec`、`FFIObserveSpec`、`Acceptance9Spec`…）呼叫的是 `Magic.FFI` 裡的**普通 Haskell 函式**——測試進程的 RTS 一開始就是起來的，`.def` 匯出清單沒有被行使過，`pm_init` 那條 C 路徑沒有被走過，關閉語意沒有被觀察過。design.md「使用的技術」那一列說得最直白：**in-process 測試對匯出清單、RTS 啟動、防火牆與關閉語意這四件事全部盲**。

本功能交付 M8：一個**純 C、不連結任何 Haskell 套件**的測試程式，住 `test/oop/`，由系統 C 編譯器建置，在**與 hspec 不同的進程**裡動態載入產出的 `.dll`／`.so`，跑完整條生命週期並比對 golden，再驗證三件 in-process 測不到的事：例外防火牆、未初始化就呼叫、關閉後重入。它建立 **I6**。

**驗收標準**（契約卡原文，逐條可機械檢查）：

1. 純 C、不連結任何 Haskell 套件的測試程式，住 `test/oop/`，由系統 C 編譯器建置；
2. 動態載入產出的共享函式庫，跑完施法→推進→觀測→釋放→關閉；
3. 輸出比對依既有的 golden 平台規則——每幀粒子數在所有平台斷言、欄位摘要只在參考平台斷言（ADR-024 落地後改為全平台）；
4. 同一程式驗證防火牆（觸發內部失敗、進程存活）；
5. 未初始化呼叫回 `PM_ERR_STATE`；
6. 關閉後重入被拒；
7. 本輪在 Windows 與 Linux 跑通；
8. hspec 只守護它在出貨清單中。

**明確不做**（契約卡）：不在 CI 安裝任何遊戲引擎；不取代 in-process 的 FFI 等價律測試（兩者互補）；不做效能量測；不以 Haskell 程式 dlopen（同進程兩個 RTS）。納入 CI 標準步驟的接線屬 authoring-engineering 的 ci-load-smoke-step，**本功能不動 `.github/workflows/ci.yml`**。

**補充的不做**（本文件裁定，屬上一條的展開）：

- **不驗證控制代碼安全**（釋放後再用、重複釋放、偽造指標）。那是 F002 handle-generation 的 C2.3，不在本契約卡的「實作的 Level 2 介面」清單（C1.1、C1.5、C2.1、C2.5）內。今天那三種情況是 UB，跨進程探測會得到平台相依的崩潰形態，價值低於噪音。
- **不驗證投影與空間摘要的 C 面**（C1.2、C1.4）。golden 檔尾端的 projection 區塊由 `Acceptance11Spec` 在 in-process 覆蓋；本功能只跑生命週期那一段。
- **不做效能量測、不印時間**。壁鐘數字進了輸出就會有人拿它當基準，那是 F011 diagnostics-stats 與 bench 的事。

## 相依性

`depends-on: [F001, F003]`——兩條都是**文檔層級的相依**（兩份文檔都還沒實作，本功能依其文檔的介面約定），由介面表反推：

| 相依 | 介面表哪一列 | 為什麼 |
|---|---|---|
| **F001** | `PM_ERR_STATE (-7)`、`firewall :: a -> IO a -> IO a` | 狀態探針的期望值是 `PM_ERR_STATE`（F001 只加常數）；毒化符號 `pm_poison_spell` 本身也套一次防火牆組合子，否則毒化路徑上的例外會從新符號穿出去 |
| **F003** | `int pm_init_ex(const PmConfig* config);`、`PmConfig`、`PM_GC_NONMOVING` | 「RTS 設定實際生效」（C1.5）與「未初始化／關閉後回 `PM_ERR_STATE`」（I3 閘門）都是 F003 的產物；本功能是那兩條的**跨進程驗收者** |

**平行性**：本功能的**程式碼可以立刻開工**——harness 的骨架、載入、生命週期與 golden 比對（T1–T5、T10）用的全部是今天就讀得到的東西（標頭的 31 個凍結符號、`examples/haskell/expected-output.txt`、`test/GoldenPlatform.hs` 的平台規則）。真正需要等的只有兩個 probe 的**期望值**，而本設計把那件事做成**執行期特徵偵測**（見「4. 還沒修 vs 修好了」）：F003 沒合併時那兩個 probe 自報 `PENDING`，合併後自動升級為斷言。所以本功能與 F001／F003 可以平行推進，只是**綠燈的定義隨對方合併而變嚴**。

與其他項的關係：

| 項目 | 關係 |
|---|---|
| **F002 handle-generation** | 不相交（本功能不碰控制代碼安全） |
| **F005 step-planner-c-abi** | 不相交。`pm_plan_steps` 落地後 harness 的符號解析表會多出一個**選配**符號（不存在即 SKIP），不需要改設計 |
| **F007 packaging-content** | 單向、非相依：harness 吃的是**一個共享函式庫的路徑**，預設指向 `cabal build` 的輸出，也可以指向 F007 打包出來的資料夾。指向後者時它順帶證明了 Linux 閉包（`$ORIGIN`）真的能被外部進程載入，但那條驗收屬 F007 的 `pack.sh --verify`，本功能不重覆 |
| **authoring-engineering／ci-load-smoke-step** | 反向相依（對方依賴本功能）。本功能只保證**退出碼與報告格式**穩定，CI 接線是對方的事 |

## 對應的 Level 2 契約

逐條對照 [design.md](../design.md)，確認未超出範圍：

| Level 2 條目 | 本功能做的事 | 是否超出 |
|---|---|---|
| **I6（M8 → 產物）** | 建立：測試以動態載入的方式驅動產出的共享函式庫，與 Haskell 測試套件**不同進程**。M8 只依賴產出的共享函式庫本身，不連結任何 Haskell 套件 | 否 |
| **C1.1 生命週期** | 驗證（不實作）：初始化／施法／推進／觀測／釋放，控制代碼為不透明指標 | 否 |
| **C1.5 執行期設定** | 驗證（不實作）：`pm_init_ex` 的 capability 數、nursery、GC 模式、RTS 統計旗標在 RTS 中**實際生效**——這正是 F003 A1／A3 明文交給本功能機械化的那一支 | 否 |
| **C2.1 例外防火牆** | 驗證（不實作）：刻意觸發內部失敗，符號回哨兵、**宿主進程存活**、庫仍可用 | 否 |
| **C2.5 關閉語意** | 驗證（不實作）：關閉後本進程不得再使用本庫，兩平台語意一致 | 否 |
| **C1「只加不改」** | **標頭一個位元都不動**；出貨的 `.def` 一個位元都不動；C# 綁定不動。毒化符號只存在於一個 flag 才建置的**獨立** foreign-library | 否 |
| **M8 的依賴紀律** | harness 只 `#include "particle_magic.h"`（讀常數與結構）與平台載入器標頭；連結面只有 Win32 `kernel32` ／ POSIX `-ldl`。Linux 的選配段落另 `#include <Rts.h>`——**只取型別版面，不連結 RTS**（實測見查證 E5） | 否 |
| 資料流管線「全段，但從宿主進程的角度」 | 走完輸入→驗證→業務處理→輸出，全部從 C 側觀察 | 否 |

**未超出的證明**：本功能不新增任何進入標頭的 C 符號、不新增任何 Haskell 匯出到 `src/ffi/Magic/FFI.hs`、不改變任何既有符號的行為。新增的三樣東西（`test/oop/` 的 harness 與腳本、一個 flag 才建置的毒化用 foreign-library、一支 hspec 守門）全部落在 M8「測試」這一格。

## 相依性查證（真實簽名與實驗結果）

以下全部是**本次執行實跑**的結果；探測程式在 scratchpad，不留在 repo。Windows 端用 ghcup 隨附的 clang（`C:\ghcup\ghc\9.14.1\mingw\bin\clang.exe`）編一支純 C 宿主，載入 `dist-newstyle/.../particle-magic-ffi.dll`；Linux 端在 `wsl -d Debian` 的 GHC 9.14.1 上用 `gcc` 編一支 `dlopen` 宿主，載入 `libparticle-magic-ffi.so`。**兩支都沒有連結任何 Haskell 套件。**

### E1 — Windows：匯出面（`GetProcAddress` 特徵偵測可行）

| 符號 | 結果 |
|---|---|
| `pm_init`、`pm_shutdown`、`pm_abi_version` | EXPORTED |
| `pm_init_ex`、`pm_plan_steps`、`pm_stats`、`pm_advance_ex` | **不存在**（F003／F005／F011 尚未落地） |
| `hs_init_ghc`、`n_capabilities`、`setNumCapabilities`、`RtsFlags`、`getRTSStatsEnabled` | **全部不存在**（`.def` 把匯出面關死了） |

結論：**「這個功能有沒有落地」可以用一次 `GetProcAddress`／`dlsym` 判斷**，這是本設計「還沒修 vs 修好了」判準的機械基礎。同時它也說明 Windows 端**無法**從 C 側讀 RTS 狀態。

### E2 — Windows：跨進程生命週期與 golden 逐行比對

純 C 宿主 `LoadLibraryA` → `pm_init` → `pm_cast(ring-fire, pos=(1.5,0.25,−2), facing=(0,0,1), seed=20260814)` → 120 × (`pm_advance(1/60f)` ＋ `pm_observe`) → `pm_age`／`pm_is_finished` → `pm_free` → `pm_shutdown`：

```
abi=1 (header 1)
frame119 digest=2423589825964152005
finished: 0
line mismatches: 0 / 120
EXIT=0
```

**120 行對 `examples/haskell/expected-output.txt` 逐字元相同**（含 `age` 與 `checksum` 兩個浮點欄）。這一條是「golden 直接沿用既有檔案、不新錄一份」的證據。

### E3 — Linux：同一支比對，跨平台差異落在既有規則之內

同樣 120 幀，對同一份 golden：

```
n_capabilities before init: readable = 0
abi=1
n_capabilities after init = 1
MISMATCH 55   golden checksum 81.830827 / mine 81.830826
MISMATCH 58   golden checksum 100.010088 / mine 100.010087
MISMATCH 61   golden checksum 127.072779 / mine 127.072778
line mismatches: 9 / 120
```

**9／120 行不同，全部在 `checksum` 欄的最後一位**；`frame`、`batches`、`particles`、`blend` 四個整數欄與 `age` 欄在 120 行上全部相同。這正是 `test/ExampleHostSpec.hs:300-318` 的註解描述的效應（libm 的 `sin`／`cos` 不保證正確捨入，累加後放大），也正是平台規則存在的理由——**本文件不需要假設這件事，它被量到了**。

### E4 — 兩平台：今天「未初始化就呼叫」與「關閉後呼叫」的可觀測訊號

以子進程執行探針，父進程只看退出狀態：

| 探針 | Windows | Linux |
|---|---|---|
| `pm_init` 之前呼叫 `pm_abi_version` | stderr `newBoundTask: RTS is not initialised; call hs_init() first`，**子進程 exit 1** | 同左，**子進程 exit 1** |
| `pm_init` → `pm_shutdown` → `pm_abi_version` | 同上訊息，**子進程 exit 1** | 同上訊息，**子進程 exit 1** |

父進程在兩平台都**完好存活**並讀到退出碼。兩件事因此確立：（1）這兩個探針**必須**跑在子進程裡，否則 harness 自己會被殺；（2）「被 RTS 殺掉」的訊號是 **exit code 1（RTS 的 `barf` 走 `exit(1)`，不是 signal）**，所以子進程用「exit 0 ＋ 印出 marker」當成功判準即可與它區分。

### E5 — Linux：純 C 能不能斷言 RTS 設定真的生效（F003 A1 交辦的那一項）

| 觀察 | 結果 |
|---|---|
| `dlsym(handle, …)` 解析 `n_capabilities`／`setNumCapabilities`／`RtsFlags`／`getRTSStats`／`getRTSStatsEnabled`／`enabled_capabilities`／`hs_init_ghc`／`hs_exit` | **全部 RESOLVES** |
| 但 `nm -D --defined-only libparticle-magic-ffi.so` | **只有 `pm_*`** |
| `dladdr` 問這些符號從哪來 | `…/libHSrts-1.0.3_thr-ghc9.14.1.so` |
| `getNumCapabilities` | **不解析**（`rts/Threads.h:74` 是 `INLINE_HEADER`，沒有實體符號） |
| 純 C 檔 `#include <Rts.h>`（`-I$(ghc --print-libdir)/*/rts-*/include`） | **編得過**；只有連結 `RtsFlags` 會失敗（本來就要走 dlsym） |
| 純 C 檔 `#include <rts/Flags.h>`（單獨） | 失敗（`stg/Types.h:147` 需要 `Rts.h` 的前置定義），必須包 `Rts.h` |
| 把 dlsym 拿到的 `RtsFlags` 轉成 `RTS_FLAGS*` 後讀值 | 成功：`pm_init` 前 `ncap=0, minAllocAreaSize=0, useNonmoving=0, getRTSStatsEnabled()=0`；`pm_init` 後 `ncap=1, minAllocAreaSize=1024, useNonmoving=0, getRTSStatsEnabled()=0` |

三個結論：

1. **修正 F003 E3-1 的措辭**：RTS 符號**不是** `.so` 自己匯出的，是**相依鏈上的 `libHSrts` 匯出的**，`dlsym` 沿 handle 的相依鏈找得到。實務結論相同（Linux 可斷言、Windows 不可），但 F007 若日後收斂 Linux 匯出面或改變閉包擺法，這條路徑會受影響。
2. **nursery 與 GC 模式可以斷言**，代價是 Linux 的 harness 要以 `-I<ghc rts include>` 編（**只包標頭、不連結**）。`minAllocAreaSize` 的單位是 blocks，`BLOCK_SIZE` = 4096（`DerivedConstants.h:16`），今天的預設 1024 blocks ＝ 4 MiB，與 F003 E2-1 相符。
3. **RTS 統計旗標可以用零版面知識斷言**：`getRTSStatsEnabled()` 回 `int`，不需要任何結構版面。這正是本文件能把「F003 新加的統計欄位有沒有生效」列為可驗證項的原因。

### E6 — 毒化符號的可行性（防火牆觸發機制）

`src/ffi/Magic/FFI.hs:35-90` 的模組匯出區確認 `SpellCell (..)` 與 `SceneCell (..)` 在「Internals（not part of the C contract; exposed for testing）」段落**已經匯出構造子**（`newtype SpellCell = SpellCell (IORef ActiveSpell)`，`:290`）。因此另一個模組可以拿到 `StablePtr SpellCell`、`deRefStablePtr`、`writeIORef ref (error "…")`，把控制代碼的內容物毒化——**這正是 F001 §5 在 in-process 用的同一招**。

`test/FFIContractSpec.hs` 的三方對帳讀的是三個**寫死的路徑**：`foreignExports` 只讀 `src/ffi/Magic/FFI.hs`（`:271`）、`defExports` 只讀 `particle-magic-ffi.def`（`:301`）、`headerFunctions` 只讀 `include/particle_magic.h`（`:283`）。所以毒化符號只要**不住在這三個檔案裡**，三方對帳一個字都不用改。`test/BindingContractSpec.hs` 的 C# 雙向對帳以標頭為來源，標頭不動就不動。這是本設計選這條路的關鍵成本理由。

## 實作方式

### 1. 形狀：一支程式、一個父進程、多個子進程探針

`test/oop/oop_smoke.c` 是**唯一**的 C 原始檔（外加建置與執行腳本）。它以子命令分派：

```
oop-smoke <library-path> --list                 印出 probe 清單與版本，退出 0
oop-smoke <library-path> --all [options]        父進程：逐一 spawn 子進程，收退出碼，印報告
oop-smoke <library-path> --probe <name> ...     子進程：只跑一個 probe，退出碼即結論
```

**父進程什麼都不載入**（連 `dlopen` 都不做），只 spawn／wait／印報告。每個 probe 各跑一個子進程，理由由查證 E4 決定：今天有兩個 probe 一定會殺死自己的進程，而**「被殺」本身就是本輪要觀察的訊號**。同時這讓「防火牆真的失效了」這種回歸也降級成一行 FAIL 而不是 harness 整個消失。

子進程的退出碼語意（父進程只認這張表）：

| 退出碼 | 意義 |
|---|---|
| 0 | probe 通過 |
| 20 | probe 跑完但斷言不符（庫回了值，只是回錯了） |
| 21 | probe 判定自己不適用，SKIP（例如毒化符號不存在） |
| 其他（含 1、signal） | **子進程沒有活著跑完**——今天 RTS 殺進程走的就是 1（E4） |

父進程依「期望」把每個結果翻成 `PASS` / `FAIL` / `SKIP` / `PENDING`，最後印一行 `oop-smoke: N passed, M failed, K skipped, P pending`，**退出碼為 0 當且僅當 `failed == 0`**。`PENDING` 不算失敗——那是「這條的實作還沒合併」，不是「壞了」。

### 2. 符號解析：一張表，兩種平台，兩種必要性

載入器只抽兩個函式：

| 抽象 | Windows | POSIX |
|---|---|---|
| 載入 | `LoadLibraryA(path)` | `dlopen(path, RTLD_NOW)` |
| 解析 | `GetProcAddress(h, name)` | `dlsym(h, name)` |

符號表分三級：

- **必要（31 個凍結符號）**：任何一個解析不到就是 FAIL。這一條在 Windows 上順帶是**出貨匯出面的跨進程驗收**——`.def` 漏一行，這裡就紅，而 `FFIContractSpec` 只看得到文字。
- **選配（`pm_init_ex`、`pm_plan_steps`、`pm_stats`、`pm_advance_ex`…）**：解析不到只代表對應的 feature 還沒合併，用來決定期望值（見 4）。
- **測試專用（`pm_poison_spell`）**：只有毒化建置才有；解析不到就把防火牆 probe 判成 SKIP。

harness **不 `#include` 任何 Haskell 產物**，只 `#include "particle_magic.h"` 取 `PM_ABI_VERSION`、`PM_OK`、`PM_ERR_*`、`PM_BATCH_INFO_STRIDE`、`PmConfig` 與函式原型（原型只拿來寫函式指標 typedef，實際呼叫一律經解析出來的位址）。

### 3. probe `life`：生命週期與 golden

**golden 直接沿用 `examples/haskell/expected-output.txt`，不新錄一份。** 理由是這份檔案已經被**兩邊夾住**：`ExampleHostSpec` S3 用 `Magic.Interface` 獨立重算它，S4 用 in-process 的 C ABI 路徑重現它（`test/ExampleHostSpec.hs:148-163`）。本功能讓**第三條路徑——跨進程載入真正的 `.dll`／`.so`——**也重現同一份檔案，於是「out-of-process 與 in-process 看到同一個模擬」變成一句被檢查過的話。新錄一份 golden 反而會製造一個沒有人重算的檔案。

probe 的動作序列**逐字對齊 `examples/c/main.c`**（那也是 golden 被錄下來時的呼叫順序）：

1. `pm_init()`；`pm_abi_version() == PM_ABI_VERSION` 否則 FAIL；
2. `cap = pm_max_particles()`，`cap > 0`，**六欄以 `cap` 配置**（不是用 `PM_MAX_PARTICLES` 巨集——標頭 `:100-109` 說得很清楚巨集是凍結值、查詢才是實況；順帶驗了這個查詢）；
3. 讀 `assets/spells/ring-fire.json`，`pm_cast(json, {1.5,0.25,−2}, {0,0,1}, 20260814, err, sizeof err)`，NULL 即 FAIL 並印 `err`；
4. 120 幀：`pm_advance(spell, 1.0f/60.0f)` → `pm_observe(...)`，`batches < 0` 即 FAIL；用 `batch_info[4i+1]` 加總粒子數、`batch_info[2]` 取 blend、五欄（x、y、z、size、life）以 **C 宿主的結合順序**累加成 `checksum`；
5. 每幀組出一行 `frame %3d  age %8.5f  batches %d  particles %4d  blend %d  checksum %.6f` 並與 golden 的對應行比對（平台規則見下）；
6. `pm_is_finished(spell)` 組出 `finished: %d` 與 golden 比對；
7. `pm_free(spell)`；`pm_shutdown()`；**再 `pm_shutdown()` 一次**（既有承諾：關閉是冪等的，`examples/c/main.c:144-145` 就這樣寫）。

golden 檔的第一行（`spell: …`）與 `finished:` 之後的 projection 區塊由 probe 跳過。

**平台規則**（把 `test/ExampleHostSpec.hs:319-343` 的 `sameLine` 逐條搬進 C，`GoldenPlatform.referencePlatform`（`os == "mingw32"`）在 C 側就是 `#ifdef _WIN32`）：

| 欄位 | 參考平台（Windows） | 非參考平台 |
|---|---|---|
| `frame`、`batches`、`particles`、`blend` 與所有非數字詞 | 逐字元相等 | **逐字元相等**（這就是「每幀粒子數在所有平台斷言」） |
| `age`、`checksum` | 逐字元相等 | 相對容差 `1e-5`：`|x−y| <= 1e-5 * (1 + max(|x|,|y|))` |

**為什麼是容差而不是略過**：契約卡說「依既有的 golden 平台規則」，而**這一份 golden 的既有規則**就是 `sameLine` 的容差版（`PerfGoldenSpec` 的「非參考平台整個略過摘要」是另一份 golden 的規則，因為那份的摘要是 FNV 雜湊，差一個 bit 就完全不同，沒有容差可言）。E3 量到的實際偏差是末位 1，遠在容差內；把它改成略過會**降低**非參考平台的覆蓋。ADR-024 落地後這張表整個塌成一欄（全平台逐字元），改動是刪掉 `#ifdef` 那一支。

**欄位摘要另印一份 FNV-1a 診斷**：probe 每幀依 `PerfGoldenSpec.digestOf`／`fnv1a`（`test/PerfGoldenSpec.hs:142-162`）的定義，對六欄（含 `color`）的原始位元樣式算 FNV-1a 64，最後一幀的值印進報告（Windows 實測 `2423589825964152005`，E2）。**這是診斷不是斷言**——它沒有被重算的 golden，斷言它等於一個committed 常數會製造一個沒人守的真相。它的用途是 ADR-024 落地時把它升級成全平台斷言的現成材料，以及人工比對兩平台時的一眼可讀值。

### 4. 還沒修 vs 修好了：期望值由特徵偵測決定

三個狀態 probe（`state-uninit`、`state-after-shutdown`、`state-reinit`）今天會殺死自己的子進程（E4），F003 落地後會回 `PM_ERR_STATE`。**判準是 `pm_init_ex` 是否解析得到**（E1 證明這個偵測可行，且 I3 閘門與 `pm_init_ex` 是 F003 的同一批產物）：

| `pm_init_ex` | 子進程結果 | 父進程判定 |
|---|---|---|
| 不存在 | 非 0（被殺） | **PENDING** — `I3 gate not landed (F003)`，不計失敗 |
| 不存在 | 0（居然活著） | **FAIL** — 這代表狀態機語意在沒有 `pm_init_ex` 的情況下改變了，值得有人看一眼 |
| 存在 | 0 且回值正確 | **PASS** |
| 存在 | 20（活著但回錯值） | **FAIL** |
| 存在 | 非 0（被殺） | **FAIL** — F003 的 I3 沒兌現 |

三個 probe 各自做的事：

- **`state-uninit`**：不呼叫任何初始化，直接對閘門符號取樣——`pm_max_particles()` 應回 `PM_ERR_STATE`、`pm_cast(...)` 應回 `NULL`（且 `err_buf` 是 NUL 結尾的可讀 ASCII）、`pm_advance(NULL, 0.016f)` 應安靜返回、`pm_age(NULL)` 應回 `-7.0`、`pm_occupancy_mask(NULL)` 應回 `0`、`pm_abi_version()` 應回 `1`（F003 A2 讓它在任何狀態下都答得出來）。取樣涵蓋 F003 哨兵表的每一種回傳型別各一個代表，不是全部 29 個——全表的斷言在 F003 自己的 `FFIRuntimeSpec` T7。
- **`state-after-shutdown`**：`pm_init()` → 一次成功的 cast／advance／observe／free（證明庫本來是好的）→ `pm_shutdown()` → 對同一組代表符號取樣，期望與上一條相同；再 `pm_shutdown()` 一次應為無操作。
- **`state-reinit`**：`pm_init()` → `pm_shutdown()` → `pm_init()`（應為無操作、不重啟、不殺進程）→ `pm_init_ex(&cfg)` 應回 `PM_ERR_STATE`。這是 C2.5「本進程不得再使用本庫」的正面表述。

### 5. probe `rts-config`：C1.5 真的生效了嗎

只有 `pm_init_ex` 存在時才跑，否則 PENDING。子進程做：

```
PmConfig cfg; memset(&cfg, 0, sizeof cfg);
cfg.size          = (uint32_t)sizeof cfg;
cfg.capabilities  = 2;
cfg.nursery_bytes = 64u * 1024u * 1024u;
cfg.gc_mode       = PM_GC_NONMOVING;
#ifdef PM_OOP_HAS_RTS_STATS
cfg.<統計欄位>    = 1;
#endif
rc = pm_init_ex(&cfg);            /* 必須是 PM_OK：這是「RTS 由我們啟動」的 3a 支 */
```

斷言分平台（E1／E5 決定，不是偏好）：

| 斷言 | Windows | Linux |
|---|---|---|
| `pm_init_ex` 回 `PM_OK` | ✔ | ✔ |
| 之後完整生命週期仍跑得完（cast→advance→observe→free） | ✔ | ✔ |
| `*(uint32_t*)dlsym("n_capabilities") == 2` | ✘ 不匯出 | ✔ |
| `((RTS_FLAGS*)dlsym("RtsFlags"))->GcFlags.minAllocAreaSize == 64 MiB / BLOCK_SIZE` | ✘ | ✔（需 `PM_OOP_WITH_RTS_HEADERS`） |
| `((RTS_FLAGS*)dlsym("RtsFlags"))->GcFlags.useNonmoving == true` | ✘ | ✔（同上） |
| `((int(*)(void))dlsym("getRTSStatsEnabled"))() != 0` | ✘ | ✔（**零版面知識**，不需要 `Rts.h`） |

Windows 上那五條印成 `SKIP: RTS symbols are not exported on this platform (.def)`，不是靜默略過——這句話本身就是 F003 逐平台表的跨進程佐證。

**`PM_OOP_WITH_RTS_HEADERS`** 由 `build.sh` 在找得到 `$(ghc --print-libdir)/*/rts-*/include/Rts.h` 時自動加上；找不到就少那兩條斷言（`getRTSStatsEnabled` 那條不受影響）。**`PM_OOP_HAS_RTS_STATS`** 由 `build.sh`／`build.ps1` grep 標頭裡的統計欄位名決定——F003 的 `PmConfig` 正在加這一欄，名字尚未定案，所以本設計不寫死它，見待確認假設 A5。

這一條 probe 就是 F003 A1 與 A3 明文交辦給本功能的機械化：「RTS 由我們啟動」那一支 in-process 永遠測不到，因為 hspec 進程的 RTS 一開始就起來了。

### 6. probe `firewall`：怎麼在 C 側觸發內部失敗

F001 A3 把這個機制的裁決交給本文件。**裁決：cabal flag `oop-poison` ＋ 一個獨立的 foreign-library ＋ 一個測試專用符號 `pm_poison_spell`。**

先說為什麼不是別的：

| 替代方案 | 否決理由 |
|---|---|
| 用合法呼叫誘發真的內部失敗（深巢狀 JSON、巨大 `dim`、堆積耗盡） | 找得到就是**缺陷**，該修不該當測試夾具；而且跨平台不可重現（F001 A3 已評估並否決） |
| 在出貨的庫加一個必定拋例外的符號 | 標頭／`.def`／C# 綁定三方對帳全部要跟著動，而且出貨面多一個永遠不該被呼叫的符號 |
| 在出貨的 `.def` 加符號但不進標頭 | 直接打破 `FFIContractSpec` 的「`.def` ≡ 標頭宣告」（`:301` vs `:283`），那條凍結對帳的價值高於本測試 |
| 讀環境變數切換行為 | 出貨的庫的行為變成環境相依，違反「RTS 是宿主的、庫不自作主張」 |

採用的形狀：

1. **flag**：`flag oop-poison`，`default: False`、`manual: True`。
2. **獨立 foreign-library `particle-magic-ffi-poison`**：`if !flag(oop-poison)` 時 `buildable: False`，所以 `cabal build all` 預設**完全不建它**（那顆 standalone DLL 連結很貴，不能白付）。它的產物檔名與出貨的**不同**（`particle-magic-ffi-poison.dll`／`libparticle-magic-ffi-poison.so`），所以永遠不可能被誤當成出貨產物——這是比 flag 更硬的防呆。它 `hs-source-dirs: src/ffi, test/oop/poison`、`other-modules: Magic.FFI, Magic.FFI.Poison`，其餘欄位（`type`、`c-sources`、`include-dirs`、`build-depends` 白名單、`ghc-options`）與出貨的那一個**逐字相同**。
3. **`test/oop/poison/Magic/FFI/Poison.hs`**：整個模組只有一個匯出：

   ```haskell
   foreign export ccall pm_poison_spell :: StablePtr SpellCell -> IO ()

   -- 把控制代碼的內容物換成一顆會爆的 thunk。本體不拋例外（不然
   -- 就變成在測我們自己），失敗要發生在之後被呼叫的「真正的」符號裡。
   pm_poison_spell :: StablePtr SpellCell -> IO ()
   pm_poison_spell h = firewall () $ do
     SpellCell ref <- deRefStablePtr h
     writeIORef ref (error "pm_poison_spell: deliberate internal failure (F006)")
   ```

   它住在 `src/ffi` **之外**，所以 `FFIContractSpec.foreignExports`（只讀 `src/ffi/Magic/FFI.hs`）與 F001 的原始碼守門測試（同一個剖析手法）都看不到它——**三方對帳零改動**。
4. **`test/oop/particle-magic-ffi-poison.def`**：出貨 `.def` 的內容加一行 `pm_poison_spell`。它會鏽掉，所以由守門測試釘住：兩個檔案的 `EXPORTS` 集合差集必須**恰好**是 `{pm_poison_spell}`。

probe 的動作（跑在子進程裡，因為「防火牆失效」的表現就是進程死掉）：

1. `pm_init()` → 正常 cast → `pm_advance` ＋ `pm_observe` 一幀成功（證明起點是好的）；
2. `pm_poison_spell(spell)`；
3. 逐一呼叫**真正的出貨符號**並斷言 F001 哨兵表：`pm_observe(...) == PM_ERR_INTERNAL(−6)`、`pm_is_finished(...) == −6`、`pm_age(...) == −6.0`、`pm_occupancy_mask(...) == 0`、`pm_advance(...)` 安靜返回、`pm_spell_bounds(...) == −6`；
4. `pm_free(spell)`（F001 T6：不強制求值，安全的無操作）；
5. **再 cast 一次全新的法術並跑一幀**——證明庫在防火牆攔截之後**仍然可用**，而不只是沒死；
6. `pm_shutdown()`，子進程 exit 0。

`pm_poison_spell` 解析不到時（載入的是出貨版本）整個 probe 回 21 ＝ SKIP，父進程印 `SKIP: shipping build has no trigger; run with the oop-poison library`。**「同一程式驗證防火牆」因此成立**：是同一支 harness、同一組 probe 名稱，只是餵不同的庫。

### 7. 建置與執行

四支腳本，職責一致、退出碼即結論：

| 腳本 | 做什麼 |
|---|---|
| `test/oop/build.ps1` | 依序找 `cl.exe`（vcvars 之後）→ ghcup 隨附 `clang.exe` → `gcc`，以 `-I include` 編出 `oop-smoke.exe`。連結面只有 C 執行期與 `kernel32` |
| `test/oop/build.sh` | `${CC:-cc} -I include test/oop/oop_smoke.c -o oop-smoke -ldl`；若 `$(ghc --print-libdir)/*/rts-*/include/Rts.h` 存在則追加 `-I` 與 `-DPM_OOP_WITH_RTS_HEADERS`；grep 標頭決定 `-DPM_OOP_HAS_RTS_STATS` |
| `test/oop/run.ps1` / `test/oop/run.sh` | 建置（若尚未）＋ 定位共享函式庫（預設 `dist-newstyle/**/particle-magic-ffi.{dll,so}`，可用參數指向 F007 打包出來的資料夾）＋ 以 repo 根目錄為 cwd 執行 `--all` |

**不設 `-Werror`、不追求零警告**：這支程式的價值在它跑得起來、跑得到位，不在它漂亮。**不進 cabal 的任何 stanza**——它由系統 C 編譯器建置，這是契約卡明文。

`Rts.h` 那條 `-I` 值得說一句：它**只取型別版面**（`RTS_FLAGS` 的欄位偏移），連結面一個 Haskell 符號都沒有（E5 實測連結 `RtsFlags` 會失敗，正是因為它只從 dlopen 來）。「不連結任何 Haskell 套件」因此仍然成立。

### 8. hspec 的守門範圍

契約卡：「hspec 只守護它在出貨清單中」。新增 `test/OopSmokeSpec.hs`，沿用 `ExampleHostSpec` S5 的手法（`test/ExampleHostSpec.hs:364-365,395-398`：列目錄、比對 `extra-source-files`），**不執行 harness、不載入任何共享函式庫**。它守四件事：

1. **出貨清單**：`test/oop/` 底下每一個 checked-in 檔案都出現在 `particle-magic.cabal` 的 `extra-source-files`（`examples/c/main.c` 早就在那裡，這是同一條紀律）。
2. **毒化 `.def` 不鏽**：`test/oop/particle-magic-ffi-poison.def` 的 `EXPORTS` 集合 減去 出貨 `.def` 的 `EXPORTS` 集合 **恰為** `{pm_poison_spell}`，反向差集為空。
3. **毒化建置不會外洩**：cabal 有 `flag oop-poison` 且 `default: False`、`manual: True`；`foreign-library particle-magic-ffi-poison` 的 stanza 內含 `buildable: False` 那一支；出貨那個 stanza 的 `other-modules` **不含** `Magic.FFI.Poison`。
4. **README 與程式碼同步**：`test/oop/README.md` 列出的 probe 名稱集合 ＝ `oop_smoke.c` 裡註冊的 probe 名稱集合（雙向相等）。

第 2、3 條稍微超出「只守護出貨清單」的字面，理由寫在待確認假設 A8：沒有它們，毒化面會靜默鏽掉或靜默外洩，而那兩件事沒有任何其他機制會發現。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `void pm_init(void);` | `include/particle_magic.h`:164 | - | 生命週期起點；狀態 probe 的受測對象 |
| `void pm_shutdown(void);` | `include/particle_magic.h`:167 | - | 關閉語意（C2.5）的受測對象；冪等性亦驗 |
| `int pm_abi_version(void);` | `include/particle_magic.h`:170 | - | 載入後第一件事；也是狀態 probe 裡「任何狀態都答得出來」的那一個（F003 A2） |
| `int pm_max_particles(void);` | `include/particle_magic.h`:176 | - | 六欄容量的來源（不用凍結巨集）；順帶驗證查詢本身 |
| `PmSpell* pm_cast(const char* circle_json, const float caster_pos[3], const float caster_facing[3], uint64_t seed, char* err_buf, int err_len);` | `include/particle_magic.h`:183-185 | - | 施法；錯誤時讀 `err_buf` |
| `void pm_advance(PmSpell* spell, float dt);` | `include/particle_magic.h`:199 | - | 每幀推進，`dt` 為 `1.0f/60.0f` |
| `int pm_is_finished(const PmSpell* spell);` | `include/particle_magic.h`:202 | - | golden 的 `finished:` 行 |
| `double pm_age(const PmSpell* spell);` | `include/particle_magic.h`:205 | - | golden 的 `age` 欄 |
| `int pm_observe(PmSpell* spell, float* pos_x, float* pos_y, float* pos_z, float* size, float* life, uint32_t* color, int capacity, int* batch_info, int max_batches);` | `include/particle_magic.h`:228-231 | - | 每幀觀測；六欄與 `batch_info` 是 golden 與 FNV 摘要的來源 |
| `void pm_free(PmSpell* spell);` | `include/particle_magic.h`:290 | - | 釋放；毒化 probe 中亦斷言它是安全的無操作 |
| `uint32_t pm_occupancy_mask(PmSpell* spell);` | `include/particle_magic.h`:423 | - | 哨兵表裡 `uint32_t` 那一類的代表 |
| `int pm_spell_bounds(const PmSpell* spell, float out_min[3], float out_max[3]);` | `include/particle_magic.h`:387 | - | 哨兵表裡「回計數／錯誤碼」那一類的第二個代表 |
| `#define PM_ABI_VERSION 1` | `include/particle_magic.h`:98 | - | 載入後的世代比對 |
| `#define PM_MAX_PARTICLES 4096` | `include/particle_magic.h`:102 | - | 只用來對照「巨集是凍結值、查詢是實況」；容量不從它來 |
| `#define PM_OK 0` / `#define PM_ERR_ARGS (-4)` | `include/particle_magic.h`:114,118 | - | `pm_init_ex` 與觀測路徑的期望值 |
| `#define PM_BATCH_INFO_STRIDE 4` | `include/particle_magic.h`:158 | - | `batch_info` 的索引算術 |
| `EXPORTS` 清單（31 個符號） | `particle-magic-ffi.def`:7-38 | - | 必要符號表的來源；毒化 `.def` 的差集守門以它為基準 |
| `#define PM_ERR_INTERNAL (-6)` | `include/particle_magic.h`（尚未實作） | **F001** | 毒化 probe 的期望哨兵；`pm_age` 的 `-6.0`、`pm_occupancy_mask` 的 `0` 亦出自 F001 哨兵表 |
| `#define PM_ERR_STATE (-7)` | `include/particle_magic.h`（尚未實作） | **F001** | 三個狀態 probe 的期望值 |
| `firewall :: a -> IO a -> IO a` | `src/ffi/Magic/FFI.hs`（尚未實作，F001「新增的介面」） | **F001** | 毒化符號自身也套一次，避免新符號成為防火牆的破口 |
| `int pm_init_ex(const PmConfig* config);` | `include/particle_magic.h`（尚未實作，F003「新增的介面」） | **F003** | C1.5 probe 的受測對象；同時是「I3 閘門是否已落地」的特徵偵測依據 |
| `typedef struct PmConfig { uint32_t size; uint32_t capabilities; uint64_t nursery_bytes; uint32_t gc_mode; uint32_t reserved; } PmConfig;` | `include/particle_magic.h`（尚未實作，F003） | **F003** | probe 填入的設定；`size` 欄填 `sizeof(PmConfig)` |
| `#define PM_GC_NONMOVING 1` | `include/particle_magic.h`（尚未實作，F003） | **F003** | 要求 nonmoving GC，並在 Linux 斷言它生效 |
| `newtype SpellCell = SpellCell (IORef ActiveSpell)`（構造子已匯出） | `src/ffi/Magic/FFI.hs`:290（匯出於 `:35-90` 的 Internals 區） | - | 毒化模組取出 `IORef` 並寫入會爆的 thunk |
| `deRefStablePtr :: StablePtr a -> IO a` | `base`，`Foreign.StablePtr` | - | 毒化模組解參考控制代碼 |
| `writeIORef :: IORef a -> a -> IO ()` | `base`，`Data.IORef` | - | 毒化模組寫入 thunk |
| `foreign-library particle-magic-ffi` stanza（`type: native-shared`；`if os(windows)` 下 `options: standalone` 與 `mod-def-file: particle-magic-ffi.def`；`hs-source-dirs: src/ffi`；`other-modules: Magic.FFI`；`c-sources: cbits/pm_init.c`；`include-dirs: include`；`build-depends: base ^>=4.22, particle-magic:magic-boundary, bytestring ^>=0.12, vector ^>=0.13`；`ghc-options: -Wall -O2 -threaded`） | `particle-magic.cabal`:230-247 | - | 毒化 stanza 逐字複製它，只多兩個欄位與一個 `.def` |
| `extra-source-files:`（含 `examples/c/main.c`） | `particle-magic.cabal`:40-48 | - | `test/oop/` 的檔案加進同一份清單，由新守門測試比對 |
| `expected-output.txt`（130 行：`spell:` 一行、120 幀、`finished:` 一行、projection 區塊） | `examples/haskell/expected-output.txt` | - | **本功能唯一的 golden**；probe 逐行比對前 122 行 |
| `testCtx = CastContext { casterPos = V3 1.5 0.25 (-2), casterFacing = V3 0 0 1, seed = Seed 20260814 }` | `test/FFIHarness.hs`:71-77 | - | probe 的施法上下文常數；與 `examples/c/main.c:67-68,101` 相同 |
| `frames = 120` / `dtFloat = 1 / 60` / `hostCapacity = 16384, hostMaxBatches = 8` | `test/ExampleHostSpec.hs`:99,103,109-111 | - | golden 的錄製參數；probe 必須用同一組（`max_batches` 較小會變成 `PM_ERR_CAPACITY`） |
| `sameLine :: String -> String -> Expectation`（參考平台逐字元；否則 tokenize 後數值以 `abs (x - y) <= 1e-5 * (1 + max (abs x) (abs y))` 比對） | `test/ExampleHostSpec.hs`:319-343 | - | 平台規則的權威；probe 在 C 側重寫同一條規則 |
| `referencePlatform = os == "mingw32"` / `platformScopeNote :: String` | `test/GoldenPlatform.hs`:39-40,45-52 | - | 「參考平台」的定義；C 側等價物是 `#ifdef _WIN32`，失敗訊息沿用同樣的解釋語氣 |
| `digestOf :: FrameOutput -> Frame`（六欄的 `castFloatToWord32` ＋ `pbColor`）/ `fnv1a :: [Word32] -> Word64`（種子 `0xcbf29ce484222325`、質數 `0x100000001b3`、每個字取小端四個位元組） | `test/PerfGoldenSpec.hs`:142-162 | - | FNV 摘要的定義；probe 在 C 側重寫，供診斷與 ADR-024 之後升級為斷言 |
| `headerFunctions :: IO [String]` / `headerDefines :: IO [(String, Int)]` / `readUtf8 :: FilePath -> IO String`（已匯出給 `BindingContractSpec` 用） | `test/FFIContractSpec.hs`:283,314,351（匯出於 `:18-25`） | - | 新守門測試沿用標頭剖析與 UTF-8 讀取，不做第二份 |
| `defExports :: IO [String]`（讀 `particle-magic-ffi.def` 的 `EXPORTS`） | `test/FFIContractSpec.hs`:301-312 | - | **模組內部、未匯出**：毒化 `.def` 的差集守門沿用同一個剖析形狀，在新 spec 內自帶一份（本 repo 的既有紀律：spec 之間各帶自己的小工具） |
| `foreignExports :: IO [String]`（只讀 `src/ffi/Magic/FFI.hs`） | `test/FFIContractSpec.hs`:271-281 | - | **只讀不改**：本設計把毒化符號放在 `src/ffi` 之外，正是為了讓這一列不動 |
| `extraSourceFiles :: IO [FilePath]` / `exampleFiles :: IO [FilePath]`（列目錄 ↔ cabal 欄位雙向比對） | `test/ExampleHostSpec.hs`:364-365,395-398 | - | 出貨清單守門的手法來源 |
| `{-# OPTIONS_GHC -F -pgmF hspec-discover #-}` | `test/Spec.hs`:1 | - | 新 spec 自動被發現，但仍要進 cabal `other-modules` |
| `extern uint32_t n_capabilities;` | `$(ghc --print-libdir)/*/rts-1.0.3/include/rts/Threads.h`:72 | - | Linux 斷言 capability 數（`getNumCapabilities` 是 `INLINE_HEADER`，沒有實體符號，見 E5） |
| `int getRTSStatsEnabled (void);` | `$(ghc --print-libdir)/*/rts-1.0.3/include/RtsAPI.h`:284 | - | Linux 斷言「RTS 統計旗標真的開了」——零版面知識 |
| `extern RTS_FLAGS RtsFlags;`；`uint32_t minAllocAreaSize; /* in *blocks* */`；`bool useNonmoving;` | `.../rts-1.0.3/include/rts/Flags.h`:361,46,56 | - | Linux 斷言 nursery 與 GC 模式（需 `#include <Rts.h>` 取版面，只包標頭不連結） |
| `#define BLOCK_SIZE 4096` | `.../rts-1.0.3/include/DerivedConstants.h`:16 | - | `nursery_bytes` ↔ `minAllocAreaSize`（blocks）的換算 |
| `HMODULE LoadLibraryA(LPCSTR)` / `FARPROC GetProcAddress(HMODULE, LPCSTR)` / `BOOL CreateProcessA(...)` / `BOOL GetExitCodeProcess(HANDLE, LPDWORD)` | Win32 `windows.h` | - | Windows 的載入、解析與子進程觀察 |
| `void* dlopen(const char*, int)` / `void* dlsym(void*, const char*)` / `pid_t fork(void)` / `int execv(const char*, char* const[])` / `pid_t waitpid(pid_t, int*, int)` | POSIX `dlfcn.h`、`unistd.h`、`sys/wait.h` | - | Linux／macOS 的載入、解析與子進程觀察（`WIFSIGNALED`／`WEXITSTATUS` 判別被殺） |

## 新增的介面

**沒有任何一項是進入 `include/particle_magic.h` 的 C 符號、進入 `src/ffi/Magic/FFI.hs` 的 Haskell 匯出，或進入出貨 `.def` 的名字。** `PM_ABI_VERSION` 不動。

### N1 harness 的命令列與退出碼契約（authoring-engineering 消費的那一面）

| 形式 | 語意 |
|---|---|
| `oop-smoke <lib> --list` | 印出 probe 名稱一行一個，退出 0 |
| `oop-smoke <lib> --all [--spell <path>] [--golden <path>]` | 跑全部 probe，印報告，`failed == 0` 時退出 0，否則 1 |
| `oop-smoke <lib> --probe <name> [...]` | 子進程模式；退出碼 0／20／21／其他（見「實作方式 1」） |
| 報告行格式 | `probe <name>: PASS|FAIL|SKIP|PENDING [ — reason]`，最後一行 `oop-smoke: N passed, M failed, K skipped, P pending` |

### N2 probe 清單（名稱是契約，README 與程式碼雙向對帳）

| probe | 驗證的 Level 2 條目 |
|---|---|
| `load` | C1.1 的匯出面；Windows 上順帶是 `.def` 的跨進程驗收 |
| `life` | C1.1 全段 ＋ golden 平台規則 |
| `state-uninit` | C2.5／I3（未初始化） |
| `state-after-shutdown` | C2.5／I3（關閉後） |
| `state-reinit` | C2.5（關閉後不得再初始化） |
| `rts-config` | C1.5 |
| `firewall` | C2.1 |

### N3 測試專用建置面（不進出貨）

| 名稱 | 說明 |
|---|---|
| `flag oop-poison` | `default: False`、`manual: True`。唯一作用是讓下一列變成可建置 |
| `foreign-library particle-magic-ffi-poison` | `if !flag(oop-poison)` 時 `buildable: False`。欄位與出貨 stanza 逐字相同，另加 `test/oop/poison` 到 `hs-source-dirs`、`Magic.FFI.Poison` 到 `other-modules`，Windows 用 `test/oop/particle-magic-ffi-poison.def` |
| `Magic.FFI.Poison` | 一個模組、一個匯出：`foreign export ccall pm_poison_spell :: StablePtr SpellCell -> IO ()` |
| `test/oop/particle-magic-ffi-poison.def` | 出貨 `.def` ＋ 一行 `pm_poison_spell`，差集由守門測試釘住 |

### N4 檔案

| 路徑 | 內容 |
|---|---|
| `test/oop/oop_smoke.c` | harness 全部的 C 程式碼 |
| `test/oop/build.sh` / `test/oop/build.ps1` | 選 C 編譯器、決定兩個特徵巨集、編出執行檔 |
| `test/oop/run.sh` / `test/oop/run.ps1` | 定位共享函式庫、以 repo 根為 cwd 跑 `--all` |
| `test/oop/README.md` | probe 清單、退出碼表、兩種建置模式、PENDING／SKIP 的意思 |
| `test/OopSmokeSpec.hs` | 四條守門（出貨清單、`.def` 差集、flag 不外洩、README ↔ 程式碼） |

## TodoList

- [ ] T1: `test/oop/oop_smoke.c` 骨架：平台載入器抽象（`LoadLibraryA`／`GetProcAddress` ↔ `dlopen`／`dlsym`）、probe 註冊表與 `--list`／`--all`／`--probe` 分派、報告行與退出碼契約　`dep: -`
- [ ] T2: probe `load`：31 個凍結符號全部解析成功（缺一即 FAIL）、`pm_abi_version() == PM_ABI_VERSION`、`pm_max_particles() > 0` 並以其值配置六欄　`dep: T1`
- [ ] T3: probe `life`：`examples/c/main.c` 的呼叫序列跑完 120 幀 ＋ `finished:` 行，與 `examples/haskell/expected-output.txt` 逐行比對　`dep: T2`
- [ ] T4: golden 的平台規則搬進 C：整數欄與非數字詞全平台逐字元；`age`／`checksum` 在 `#ifdef _WIN32` 外走 `1e-5` 相對容差，失敗訊息帶 `platformScopeNote` 同語氣的說明　`dep: T3`
- [ ] T5: 每幀六欄（含 `color`）的 FNV-1a 64 摘要，依 `PerfGoldenSpec` 的定義實作，末幀值印進報告作為診斷（不斷言）　`dep: T3`
- [ ] T6: 父進程的子進程機制：Win32 `CreateProcessA` ＋ `GetExitCodeProcess`；POSIX `fork` ＋ `execv` ＋ `waitpid`（`WIFSIGNALED` 一律視為「沒活著跑完」），把 0／20／21／其他翻成 PASS／FAIL／SKIP／PENDING　`dep: T1`
- [ ] T7: probe `state-uninit`／`state-after-shutdown`／`state-reinit`：各型別回傳一個代表符號的哨兵斷言；期望值由 `pm_init_ex` 是否解析得到決定（不存在 ⇒ PENDING，存在 ⇒ 必須回 `PM_ERR_STATE` 且子進程 exit 0）　`dep: T6, F003`
- [ ] T8: probe `rts-config`：`pm_init_ex` 帶 capabilities=2／nursery=64 MiB／`PM_GC_NONMOVING`／統計旗標；Linux 以 dlsym 的 `n_capabilities`、`RtsFlags`（需 `PM_OOP_WITH_RTS_HEADERS`）、`getRTSStatsEnabled()` 四項斷言，Windows 只斷言 `PM_OK` ＋ 後續生命週期並印 SKIP 理由　`dep: T7`
- [ ] T9: 毒化建置面：`flag oop-poison`、`foreign-library particle-magic-ffi-poison`（`buildable: False` 除非開旗標）、`test/oop/poison/Magic/FFI/Poison.hs`、`test/oop/particle-magic-ffi-poison.def`　`dep: F001`
- [ ] T10: probe `firewall`：cast → 一幀成功 → `pm_poison_spell` → 六個真實符號各自回哨兵 → `pm_free` 安全 → **新的一次 cast 仍成功** → exit 0；`pm_poison_spell` 不存在時回 21（SKIP）　`dep: T9, T6`
- [ ] T11: `test/oop/build.{sh,ps1}` 與 `run.{sh,ps1}`：選 C 編譯器、`-I include`、Linux 選配 `-I$(ghc --print-libdir)/*/rts-*/include` ＋ `-DPM_OOP_WITH_RTS_HEADERS`、grep 標頭決定 `-DPM_OOP_HAS_RTS_STATS`、定位共享函式庫、退出碼即結論　`dep: T1`
- [ ] T12: `test/oop/README.md`（probe 清單、退出碼表、兩種建置模式、PENDING／SKIP 語意）＋ `test/OopSmokeSpec.hs` 四條守門；新 spec 進 cabal `other-modules`，`test/oop/*` 進 `extra-source-files`　`dep: T9, T11`

## 1-to-1 測試對照表

「測試」在本功能有兩種形態：**harness 自己的 probe**（退出碼即斷言，這是契約卡要的東西）與 **hspec 守門**（不執行 harness）。兩者都列出來源。

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `oop-smoke <lib> --list` 退出碼 0 且印出 N2 的七個 probe 名稱 | 骨架、註冊表與分派可用；也是 T12 第 4 條守門的比對來源 |
| T2 | probe `load` | 31 個必要符號逐一解析（缺一個就指名是哪一個）；世代相符；`pm_max_particles()` 為正且被用作容量。Windows 上這一條同時是 `.def` 匯出面的跨進程驗收 |
| T3 | probe `life` | 120 幀 ＋ `finished:` 行與 golden 相符；任何一幀 `pm_observe` 回負值即 FAIL 並印幀號。已在 Windows 實測 0／120 不符（查證 E2） |
| T4 | probe `life`（非參考平台分支） | 整數欄在兩平台皆逐字元相等；浮點欄在非參考平台走容差。已在 Linux 實測：9／120 行的 `checksum` 末位差 1、四個整數欄與 `age` 全同（查證 E3），全部落在容差內 |
| T5 | probe `life` 的報告行含 `digest=` | 末幀 FNV-1a 值可讀且穩定；同一平台重跑相同（Windows 實測 `2423589825964152005`）。**診斷不斷言**——它的斷言化是 ADR-024 落地後的動作 |
| T6 | probe `state-uninit` 在**今天**（F003 未合併）跑出 `PENDING`，父進程退出碼仍為 0 | 子進程被 RTS 殺掉（exit 1，兩平台實測）時父進程存活、正確分類、不誤報失敗——這一條是機制本身的測試 |
| T7 | probe `state-uninit`／`state-after-shutdown`／`state-reinit` | F003 合併後三條必須 PASS：`int` 類回 −7、`pm_cast` 回 `NULL` 且 `err_buf` 可讀、`void` 類安靜返回、`pm_age` 回 `-7.0`、`pm_occupancy_mask` 回 `0`、`pm_abi_version` 回 `1`；`pm_shutdown` 二次為無操作；`pm_init` 於 `CLOSED` 為無操作 |
| T8 | probe `rts-config` | F003 合併後：`pm_init_ex` 回 `PM_OK`；Linux 上 `n_capabilities == 2`、`minAllocAreaSize == 64 MiB / 4096`、`useNonmoving == true`、`getRTSStatsEnabled() != 0`；Windows 印 SKIP 並仍斷言後續生命週期跑得完 |
| T9 | `OopSmokeSpec` — `it "keeps the poison build out of the shipping one"` | `flag oop-poison` 存在且 `default: False`、`manual: True`；毒化 stanza 帶 `buildable: False` 的條件支；出貨 stanza 的 `other-modules` 不含 `Magic.FFI.Poison`；毒化 `.def` 減出貨 `.def` 恰為 `{pm_poison_spell}`、反向差集為空 |
| T10 | probe `firewall`（以毒化庫執行） | 六個真實符號各回 F001 的哨兵；`pm_free` 為安全無操作；**毒化之後新的一次 cast 仍成功**；子進程 exit 0。以出貨庫執行時回 SKIP 而非 FAIL |
| T11 | `test/oop/build.sh` 與 `build.ps1` 退出碼 0，且產出的執行檔 `--list` 可跑 | 系統 C 編譯器（實測：Windows ghcup clang、Linux gcc）能編出來；Linux 上找得到 `Rts.h` 時 `PM_OOP_WITH_RTS_HEADERS` 生效（`rts-config` 的兩條 RtsFlags 斷言從 SKIP 變成 PASS 即為證據） |
| T12 | `OopSmokeSpec` — `it "ships every file of the harness"` ＋ `it "documents exactly the probes it registers"` | `test/oop/` 每個 checked-in 檔案都在 `extra-source-files`（空清單以非空斷言擋掉，沿用 `ExampleHostSpec` S5 紀律）；README 的 probe 名稱集合與 `oop_smoke.c` 註冊表雙向相等；新 spec 已列入 cabal `other-modules` |

## 待確認假設

- **A1: golden 沿用 `examples/haskell/expected-output.txt`，不新錄一份。** → 採取：它已經被 `ExampleHostSpec` S3（`Magic.Interface` 獨立重算）與 S4（in-process C ABI 路徑重現）兩邊夾住，本功能讓第三條路徑（跨進程載入真正的 `.dll`／`.so`）重現同一份檔案；新 golden 會是一個沒人重算的真相。實測 Windows 120／120 逐字元相同。→ 影響：這份 golden 覆蓋的是五欄的和（`checksum` ＝ x＋y＋z＋size＋life）加上粒子數／批次數／blend／age，**`color` 欄不在其中**（in-process 的 `FFIObserveSpec` 覆蓋它）。若編排者要求 out-of-process 也逐位元覆蓋 `color`，路線是把 T5 的 FNV 摘要升級為斷言，並由一支 hspec 以 `FFIHarness` 重算後寫出 golden——那會讓 hspec 的角色從「只守出貨清單」變成「擁有一份 golden」。
- **A2: 平台規則採 `ExampleHostSpec.sameLine` 的容差版，而非 `PerfGoldenSpec` 的「非參考平台整個略過摘要」。** → 採取：契約卡說「依既有的 golden 平台規則」，而**這一份 golden 的既有規則**就是容差版；兩份 golden 的規則不同是因為摘要形態不同（和 vs 雜湊）。實測偏差為末位 1，遠在 `1e-5` 相對容差內。→ 影響：若編排者採嚴格字面（非參考平台不比對任何浮點欄），改動是 T4 的一個分支，覆蓋率下降但不影響任何其他設計。
- **A3: 防火牆的觸發機制。** → 採取：cabal flag `oop-poison` ＋ **獨立** foreign-library `particle-magic-ffi-poison`（預設 `buildable: False`、產物檔名不同）＋ 一個只毒化控制代碼內容物的符號 `pm_poison_spell`，失敗發生在**真正的出貨符號**裡。連帶成本已查證並**收斂到零**：`FFIContractSpec` 的三方對帳讀的是 `src/ffi/Magic/FFI.hs`（`:271`）、出貨 `.def`（`:301`）、標頭（`:283`）三個寫死路徑，毒化面三個都不碰；標頭不加符號，所以 `BindingContractSpec` 的 C# 雙向對帳也不動。**唯一的新維護面**是一份鏡像 `.def`，由 T9 的差集守門釘住。→ 影響：代價是「跑防火牆那一輪載入的不是出貨的那顆二進位」。緩解是同一支 harness 的其餘六個 probe 都跑出貨版本，且毒化版本的檔名不同、預設不建置。若編排者堅持出貨版本也要能被 C 觸發，就回到 F001 A3 的另一支：出貨面多一個符號，標頭／`.def`／C# 三方全部跟著動。
- **A4: 「還沒修 vs 修好了」以 `pm_init_ex` 是否解析得到為判準。** → 採取：`pm_init_ex` 與 I3 閘門是 F003 的同一批產物，一次符號解析就能分辨（E1 實測今天不存在）。→ 影響：若 F003 拆成兩次合併（先閘門、後 `pm_init_ex`），中間那段時間三個狀態 probe 會誤報 PENDING。屆時把判準換成「探針子進程活著回來」即可（一行）。
- **A5: F003 正在往 `PmConfig` 加一個 RTS 統計欄位，欄位名尚未定案。** → 採取：本功能不寫死名字——`build.sh`／`build.ps1` grep 標頭決定要不要定義 `PM_OOP_HAS_RTS_STATS`，未定義時 `rts-config` 少要求統計、也少一條斷言（其餘照跑）。「統計欄位是否生效」的斷言本身已查證可行且**零版面知識**：`getRTSStatsEnabled()`（`RtsAPI.h:284`）在 Linux 以 dlsym 解析得到（E5）。→ 影響：F003 定案後把 grep 的字串對上即可；若 F003 最終不加這個欄位（改由 F011 處理），這一條斷言退化為「統計未開時 `getRTSStatsEnabled() == 0`」的負向確認。
- **A6: nursery 與 GC 模式只能在 Linux 斷言。** → 採取：Linux 以 `#include <Rts.h>`（`-I$(ghc --print-libdir)/*/rts-*/include`）取得 `RTS_FLAGS` 版面，再讀 dlsym 拿到的 `RtsFlags` 指標——實測可行且**不連結任何 Haskell 套件**（E5）；Windows 因 `.def` 不匯出任何 RTS 符號（E1）只能斷言 `pm_init_ex` 回 `PM_OK` 與後續生命週期，並把差異印成 SKIP。→ 影響：`RTS_FLAGS` 是私有 ABI（F003 E2-4 已認定），GHC 換版可能改版面；緩解是 `Rts.h` 來自**當前**的 GHC，版面必然一致。若編排者要 Windows 也能機械驗證 nursery，唯一的路是 F011 的 `pm_stats` 把 RTS 旗標回報出來——那要改 F011 的結構定義（F003 A1 已經指出同一條路）。
- **A7: 子進程「被殺」的可觀測訊號。** → 採取：兩平台實測都是 **exit code 1**（RTS 的 `barf` 走 `exit(1)`，不是 signal），所以子進程以「exit 0」代表成功、「20」代表活著但回錯值、「21」代表 SKIP，其餘（含 signal）一律歸類為「沒活著跑完」。→ 影響：若日後某平台改以 signal 終止，`WIFSIGNALED` 那一支已經在設計裡，分類不變。
- **A8: hspec 守門略超出「只守護它在出貨清單中」。** → 採取：多守兩條——毒化 `.def` 的差集、毒化建置不外洩。理由是這兩件事鏽掉或外洩時，**沒有任何其他機制會發現**（毒化庫預設不建置，所以連編譯錯誤都不會有）。→ 影響：若編排者要嚴格字面，刪掉那兩條 `it`，代價是毒化面的鏽蝕只會在下次有人開旗標建置時才爆。
- **A9: harness 吃的共享函式庫預設來自 `dist-newstyle`。** → 採取：路徑是參數，`run.sh`／`run.ps1` 預設 glob `dist-newstyle`，也接受 F007 打包出來的資料夾。→ 影響：指向 F007 的產物時它順帶證明 Linux 閉包（`$ORIGIN`）能被外部進程載入，但本功能**不重覆** F007 的 `pack.sh --verify`；CI 要跑哪一種由 authoring-engineering 的 ci-load-smoke-step 決定。
- **A10: 修正 F003 E3-1 的一句敘述。** → 採取：本文件以 E5 的量測為準——Linux 的 `.so` **自己**只匯出 `pm_*`（`nm -D` 實測），RTS 符號是**相依鏈上的 `libHSrts-1.0.3_thr-ghc9.14.1.so`** 匯出的，`dlsym` 沿 handle 的相依鏈找得到（`dladdr` 實證）。實務結論與 F003 相同（Linux 可斷言、Windows 不可），但敘述不同。→ 影響：建議編排者請 F003 修訂那一句（純敘述修正，不動任何決策）；同時提醒 F007：若日後收斂 Linux 匯出面或改變閉包擺法，本功能 Linux 端的三條 RTS 斷言會受影響。
- **A11: `test/oop/` 不進 `packaging/artifacts.json`。** → 採取：那份清單是**產品產物**的權威（F007 N1），測試 harness 不是產物；本功能的「出貨清單」解讀為 cabal 的 `extra-source-files`（`examples/c/main.c` 早就在那裡，同一條紀律）。→ 影響：若編排者認為 harness 應隨產物一起發布，往 `artifacts.json` 加一個 `role` 即可，F007 的封閉詞彙要跟著加一個值。

## 實作備註

（撰寫時留空）
