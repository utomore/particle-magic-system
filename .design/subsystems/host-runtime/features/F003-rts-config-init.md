---
id: F003
type: feature
title: rts-config-init
description: 帶設定的 RTS 初始化、原子化與兩平台統一的關閉語意
status: done
created: 2026-08-20
updated: 2026-08-21
depends-on: [F001]
related-adr: [ADR-022, ADR-021]
related-feature: []
---

# F003: 帶設定的 RTS 初始化

## 功能概述

**要解決的問題**（[ADR-022](../../../adr/ADR-022-host-runtime-contract.md) 背景 2、3、7）：

1. **宿主無法設定 RTS**。`foreign-library particle-magic-ffi` 是整個 cabal 檔裡唯一沒有 `-with-rtsopts` 的 stanza（`particle-magic.cabal:247` 只有 `-Wall -O2 -threaded`），而 `cbits/pm_init.c:40-51` 交給 `hs_init` 的是寫死的一元素 argv。結果：出貨給 C／Unity 宿主的庫**永遠只有一個 capability**，nursery 與 nonmoving GC 無從指定。更糟的是核心 `sample` 在 `windowRows >= parallelThreshold`（8192，`src/core/Magic/Particle/Analytic.hs:496`）就切到分片路徑——單 capability 下那是純負收益：付了分片與串接的成本，換到零加速。
2. **初始化不是原子的**。`pm_rts_running` 是裸 `static int`（`cbits/pm_init.c:38`），兩個引擎執行緒同時 `pm_init` 是資料競爭。
3. **關閉語意沒有人擋**。`pm_shutdown` 之後再 `pm_init` 只有 `docs/integration.md:450` 說不可以，程式碼不擋——實測是**整個宿主進程被 RTS 殺掉**（見下方查證 E1-4）。同樣地，未初始化就呼叫任何符號也是殺進程（E1-2）。

本功能新增 `pm_init_ex(const PmConfig*)`，把 capability 數、nursery 大小、GC 模式交回宿主；把初始化與關閉改成一具**原子狀態機**；並在 C 側建立 **I3 閘門**，讓「未初始化／已關閉還呼叫」從殺進程變成 `PM_ERR_STATE`。

**驗收標準**（契約卡原文，逐條可機械檢查）：

1. 帶設定的初始化能指定 capability 數、nursery、GC 模式，且三者在 RTS 中**實際生效**；
2. Windows 上先查證 standalone DLL 是否真的在 `DllMain` 啟動 RTS 以及能否關閉——能關就三者全生效，不能關就套 C2.4 的降級條款，並在文件逐平台明列；
3. 無參數初始化（`void`）行為不變；
4. 兩個執行緒同時初始化只有一個生效、另一個回 `PM_OK` 或 `PM_ERR_STATE` 而非崩潰；
5. 關閉後再初始化回 `PM_ERR_STATE`；
6. 未初始化就呼叫其他符號回 `PM_ERR_STATE`（I3）；
7. Windows 與 Linux 的關閉語意一致並有測試；
8. 設定結構以 `size` 欄開頭。

第 2 條的查證**已完成**（下方「平台查證結果」）：**`DllMain` 並沒有啟動 RTS**——`cbits/pm_init.c:9-13` 的註解與事實不符。因此設定欄位在 Windows 與 Linux 上**都全數生效**，C2.4 的降級條款改為適用於另一個真實情境：**RTS 已被宿主自己啟動**（Haskell 宿主、或宿主先呼叫過 `hs_init`）。

**階段閘門增補（2026-08-20，推翻本文件初版的 A4）**：C1.5 現在讀作「capability 數、nursery 大小、GC 模式、**是否啟用 RTS 統計**」——統計旗標**無法在初始化後開啟**（E4-2），宿主不在此表態，C1.8 的 GC 數字就永遠查不到。因此 `PmConfig` 是**四個**設定欄位，驗收標準第 1 條與第 2 條的「三者」一律讀作「四者」，逐平台表也多一欄。

**明確不做**（契約卡）：不讓庫替宿主選預設以外的 capability 數；不做執行期動態調整（初始化後不改）；不處理「宿主自己已啟動 RTS」以外的 RTS 共享；不靜默忽略任何無法生效的設定。

**補充的不做**（本文件裁定，屬上一條的展開）：

- **不提供任何「重啟 RTS」的路徑**。GHC 9.14.1 明文拒絕（E1-4／E3-4），本功能只保證那個拒絕變成錯誤碼而不是屍體。
- **不改動核心的 `parallelThreshold`**。門檻與 capability 數的關係寫進文件與整合指南，程式碼一個位元都不動（見「7. 與平行取樣門檻的關係」）。
- **不新增診斷面**。本功能只負責「宿主有沒有要求 RTS 統計」這個**開關**與它在 RTS 中生效；`pm_stats` 這個符號、`PmStats` 結構、以及各欄位的語意屬 F011 diagnostics-stats。兩者的交界寫成一條可被 F011 直接消費的判準（見「2. `pm_init_ex` 的三條路徑」末段）。

## 相依性

`depends-on: [F001]`——唯一的相依是**常數 `PM_ERR_STATE`（−7）**：標頭的 `#define`、`Magic.FFI` 的 `pmErrState :: CInt`、C# 綁定的 `Pm.ErrState` 三處都由 F001 建立（F001「新增的介面」明列，且該文件寫明「語意由 F003／F004 落地」）。介面表裡有一列的「來源文檔」指向 `F001`，其餘每一列都是今天就讀得到的原始碼。

這是**文檔層級的相依**（F001 尚未實作，介面依其文檔的約定），不是程式碼相依：若 F001 尚未合併，本功能可以先實作、在自己的分支上暫時自帶那三處常數，合併時刪掉重複——但**測試會撞**（兩份 `#define` 同名），所以正常順序是 F001 先合。

與其他平行項目的關係：

| 平行項目 | 關係 |
|---|---|
| **F001 exception-firewall** | 被依賴（常數）＋ **同檔案不同層**：F001 的防火牆在 Haskell 本體最外層，本功能的閘門在 C 側、更外一層。真正的交會點是 `foreign export ccall` 那 29 行——本功能要把外部符號名改成 `pm_hs_*`，而 F001 的守門測試正是**剖析那 29 行**的。見「9. 合併順序」 |
| **F002 handle-generation** | 無相依。F002 換的是控制代碼表徵（Haskell 本體內），與 C 側閘門不相交；閘門對回傳指標的符號回 `NULL`，與 F002 的世代標籤無關 |
| **F005 step-planner-c-abi** | 無相依，但**互相要求**：F005 新增 `pm_plan_steps`／`pm_advance_ex`／`pm_scene_advance_ex` 三個 Haskell 匯出，它們必須各自進閘門清單（本功能的守門測試不寫死清單，漏一個就紅）。F005 的標頭已寫「Needs the runtime: call `pm_init()` first」，本功能就是讓那句話變成 `PM_ERR_STATE` 而不是崩潰 |
| **F006 oop-load-smoke** | 反向相依（它依賴本功能）。本功能無法在 in-process 覆蓋的那一支（「RTS 由我們啟動」），由 F006 機械化，見「8. 測試怎麼跑得起來」 |

## 對應的 Level 2 契約

逐條對照 [design.md](../design.md)，確認未超出範圍：

| Level 2 條目 | 本功能做的事 | 是否超出 |
|---|---|---|
| **C1.5 執行期設定（含 RTS 統計欄位）** | 全部實作：`pm_init_ex(const PmConfig*)`，`PmConfig` 以 `size` 欄開頭，帶 capability 數（0 ＝ 依硬體）、nursery 大小、GC 模式、**是否啟用 RTS 統計**（旗標無法在初始化後開啟，故必須在此表態），回錯誤碼；無參數初始化保留且行為不變（統計維持關閉，E4-4）；RTS 已初始化時再呼叫、或關閉後再初始化，回 `PM_ERR_STATE` | 否 |
| **C1.8 診斷的前提** | 只做「宿主有沒有要求統計」這個開關，並把 F011 該用的判準（`getRTSStatsEnabled()` 為假 → GC 欄位回報為不可用而非零）寫進標頭 | 否。`pm_stats`／`PmStats` 屬 F011 |
| **C2.4 RTS 歸宿主** | 庫預設保守（單 capability、預設 GC）、不自行開 OS 執行緒；**降級條款**依查證結果落在「RTS 已由宿主啟動」而非「Windows 載入器」，capability 數仍以執行期 API 生效，其餘回 `PM_ERR_STATE`，並逐平台文件化 | 否。條款文字不動，適用情境由查證決定 |
| **C2.5 關閉語意** | 關閉後本進程不得再使用本庫，兩平台語意一致；由**狀態機**而非 RTS 的行為保證，所以 `DllMain` refcount 的不對稱天然被吸收 | 否 |
| **I3（M2 → M1）** | 建立：任何匯出符號在 RTS 未初始化或已關閉時回錯誤，**不進入 Haskell**（這一條是字面意義的——進入 Haskell 就已經死了） | 否 |
| **C1.9 錯誤碼** | 消費 F001 加的 `PM_ERR_STATE`，定義它在每個情境下的語意（錯誤碼情境表） | 否 |
| **C1「只加不改」** | 標頭只加一個結構、五個 `#define`、一個函式宣告；`pm_init`／`pm_shutdown` 的簽名與既有 31 個宣告一個位元不動；`PM_ABI_VERSION` 維持 1 | 否。`pm_hs_*` 是**內部符號**，不進標頭、Windows 不進 `.def` |
| **C3.1 雙向對帳** | C# 綁定同步 `pm_init_ex`、`PmConfig` 與五個常數 | 否 |
| 資料流管線「輸入段之前」 | RTS 的啟動與狀態；管線本身不動 | 否 |

## 實作方式

### 0. 平台查證結果（機械證據）

契約卡第 2 條要求「先查證」。以下全部是**這次執行實跑**的結果，探測程式在 scratchpad，不留在 repo。

**E1 — Windows：真的載入 `dist-newstyle/.../particle-magic-ffi.dll`，純 C 宿主 `LoadLibraryA` 驅動**

| # | 觀察 | 結果 |
|---|---|---|
| E1-1 | DLL 匯出哪些符號 | `pm_init`／`pm_shutdown`／`pm_abi_version` 有；`hs_init`／`hs_init_ghc`／`hs_exit`／`setNumCapabilities`／`n_capabilities`／`RtsFlags`／`getRTSStats` **全部沒有**（`.def` 限制了匯出面） |
| E1-2 | `pm_init` **之前**呼叫 `pm_abi_version` | `newBoundTask: RTS is not initialised; call hs_init() first` → **進程死亡**。**`DllMain` 沒有啟動 RTS**，`cbits/pm_init.c:9-13` 的註解是錯的 |
| E1-3 | `pm_init` ×2、`pm_shutdown` ×2 | 皆正常（今天的冪等旗標有效） |
| E1-4 | `pm_init` → `pm_shutdown` → `pm_init` | `hs_init_ghc: reinitializing the RTS after shutdown is not currently supported` → **進程死亡** |
| E1-5 | `pm_shutdown` 之後呼叫 `pm_abi_version` | `newBoundTask: RTS is not initialised` → **進程死亡**。即 `pm_shutdown` 在 Windows 上**真的把 RTS 關了** |

E1-2 與 E1-5 合起來就是 I3 必須存在、而且必須在 **C 側**的證據：崩潰發生在 C→Haskell 的 stub 進入 RTS 時，任何寫在 Haskell 裡的檢查都來不及。

**E2 — 與 foreign-library 同一組旗標（`-threaded`、無 `-rtsopts`）連結的 C main，測 `hs_init_ghc` 能設定什麼**

| # | 設定手段 | 結果 |
|---|---|---|
| E2-1 | 不設定 | `n_capabilities=1`、`minAllocAreaSize=1024` blocks（4 MiB）、`useNonmoving=0`——今天出貨的樣子 |
| E2-2 | `RtsConfig.rts_opts = "-N4 -A64m --nonmoving-gc"` | `n_capabilities=4`、64 MiB、`useNonmoving=1`——**三項全生效**，且 Haskell 側 `getNumCapabilities` 也看到 4 |
| E2-3 | 同上但 `rts_opts_enabled = RtsOptsNone` | 一樣生效（`rts_opts` 是**庫作者的**通道，不受 `rts_opts_enabled` 管） |
| E2-4 | `defaultsHook` 直寫 `RtsFlags` | 同樣生效，但 `nCapabilities = 0` 時 **segfault**；`RtsFlags` 是私有 ABI |
| E2-5 | 壞字串 `-Axyz` | `error in RTS option` → **進程死亡**（所以字串必須由庫自己生成並先驗證） |
| E2-6 | `-N0` | **進程死亡**（`bad value for -N`）。`-N`（不帶數字）＝ 依硬體，回 16 |
| E2-7 | `-A0` | **進程死亡**（`size outside allowed range (8192 - …)`）。`-A16777216` 正常＝ 4096 blocks |
| E2-8 | `-N1000` | 接受，`max_n_capabilities` 隨之變成 1000（預設 256） |
| E2-9 | 初始化後 `setNumCapabilities(6)` → `(2)` | `n_capabilities` 1→6、`enabled_capabilities` 6→2，Haskell 側同步看到——**執行期改 capability 數可行** |
| E2-10 | `hs_init_ghc` 第二次（不同設定） | **靜默忽略**新設定，只加 refcount |
| E2-11 | refcount 2 時 `hs_exit` 一次 | RTS 仍活著、Haskell 呼叫正常；第二次才真的關 |
| E2-12 | 未初始化就 `hs_exit` | 只印 `warning: too many hs_exit()s`，不崩 |
| E2-13 | `GHCRTS=-N8` ＋ `rts_opts="-N2"` | **環境變數贏**（caps=8）——宿主的明確設定被蓋掉 |
| E2-14 | `GHCRTS=-A128m`（非 safe 選項） | `Most RTS options are disabled.` → **進程死亡**。今天的 `pm_init` 就有這個地雷 |
| E2-15 | `rts_opts_enabled = RtsOptsIgnoreAll` ＋ 上兩者 | 環境變數被完全忽略，宿主設定生效，**不崩、不印警告** |

E2-13／E2-14／E2-15 是本功能唯一一項超出契約卡字面的修正：`RtsOptsIgnoreAll` 同時關掉「環境變數蓋過宿主」與「環境變數殺宿主」兩個洞。

**E3 — Linux：`wsl -d Debian` 的 GHC 9.14.1 建出的 `libparticle-magic-ffi.so`，純 C 宿主 `dlopen` 驅動**

| # | 觀察 | 結果 |
|---|---|---|
| E3-1 | `.so` 上 `dlsym` 找得到哪些符號 | `pm_*` 是 `.so` 自身匯出的。`hs_init_ghc`、`setNumCapabilities`、`n_capabilities`、`RtsFlags`、`getRTSStats`… **不是 `.so` 自身匯出的**——它們由相依鏈上的 `libHSrts` 匯出，`dlsym(handle, …)` 沿著相依鏈找得到（實作期 2026-08-21 覆核：三個都拿得到非空指標）。實務結論不變：與 Windows 的 `.def` 相反，Linux 的 out-of-process 測試能直接斷言 RTS 狀態 |
| E3-2 | `pm_init` 之前呼叫 `pm_abi_version` | 進程死亡（同 E1-2） |
| E3-3 | `pm_init` 之前讀 `n_capabilities` | **0**；`pm_init` 之後 1；`pm_shutdown` 之後仍是 1（不會歸零） |
| E3-4 | `pm_shutdown` → `pm_init` | 進程死亡（同 E1-4） |
| E3-5 | `hs_init_ghc` 帶 `-N4 -A64m --nonmoving-gc` | 三項全生效（同 E2-2） |
| E3-6 | 初始化後 `setNumCapabilities` | 生效（同 E2-9） |

**E4 — RTS 統計旗標（階段閘門推翻 A4 之後補做）：同一個 C main，`rts_opts_enabled = RtsOptsIgnoreAll`，初始化後 `performGC()` 再讀統計**

| # | 設定 | 結果 |
|---|---|---|
| E4-1 | `rts_opts = "-N2 -A32m -T"` | `RtsFlags.GcFlags.giveStats=1`、**`getRTSStatsEnabled()=1`**；`performGC` 後 `gcs=1`、`gc_elapsed_ns=122800`——**統計旗標在 `RtsOptsIgnoreAll` 之下照樣由 `RtsConfig` 開得起來**，不需要 `GHCRTS`、不需要 `-rtsopts` |
| E4-2 | 同上但不帶 `-T` | `getRTSStatsEnabled()=0`；`getRTSStats()` **不崩**，但回來的是**半真半假**的結構：`gcs=1`、`allocated_bytes=243576` 是真的（那些計數器本來就在跑），**`gc_elapsed_ns=0`**——暫停時間欄位靜默為零 |
| E4-3 | `rts_opts = "-T"` ＋ `GHCRTS=-A128m` | 統計開起來（`getRTSStatsEnabled()=1`），環境變數照樣被忽略、不殺進程（與 E2-15 一致） |
| E4-4 | `rts_opts` 為空（＝今天的 `pm_init`） | `getRTSStatsEnabled()=0`——**無參數初始化的行為不變** |

E4-2 就是契約要求「**回報為不可用而非零**」的理由：`gc_elapsed_ns == 0` 在關掉統計時與「這一段真的沒有 GC 暫停」長得一模一樣。唯一誠實的判準是 `getRTSStatsEnabled()`，而不是欄位值本身。

**結論（寫進標頭與整合指南的逐平台表）**：

| 平台 | RTS 由載入器先啟動？ | `pm_shutdown` 真的關掉 RTS？ | capabilities | nursery | GC 模式 | RTS 統計 |
|---|---|---|---|---|---|---|
| Windows x86_64（standalone DLL） | **否**（E1-2） | 是（E1-5） | 生效 | 生效 | 生效 | 生效（E4-1） |
| Linux x86_64（`.so`） | 否（E3-3） | 是（E3-2、E3-4） | 生效 | 生效 | 生效 | 生效（E4-1，同一條 RTS 路徑） |
| macOS（`.dylib`） | 未實測（無機器），預期同 Linux | 預期同 Linux | 預期生效 | 預期生效 | 預期生效 | 預期生效 |
| **任一平台，但 RTS 已由宿主啟動** | — | 否（只減 refcount） | 生效（執行期 API） | **`PM_ERR_STATE`** | **`PM_ERR_STATE`** | **`PM_ERR_STATE`**（旗標只在初始化時可設） |

`n_capabilities != 0` 是「RTS 已經起來了」的可靠偵測（E3-3 兩平台一致），而且它是一個普通的全域變數讀取，在 RTS 未啟動時讀它是安全的。

### 1. 狀態機（M1）

`cbits/pm_init.c` 的 `static int pm_rts_running` 換成一具四態的原子狀態機：

```
UNINIT ──(pm_init / pm_init_ex 勝出者)──▶ INITIALIZING ──▶ RUNNING ──(pm_shutdown)──▶ CLOSED
   │                                                                                      │
   └──────────────── 其他匯出符號 → PM_ERR_STATE（I3）────────────────────────────────────┘
```

- 表徵：C11 `<stdatomic.h>` 的 `atomic_int`（GHC 9.14.1 的三平台工具鏈——Windows MinGW gcc、Linux gcc、macOS clang——都支援；`cbits` 從不由 MSVC 編譯，MSVC 只會連結匯入庫，所以沒有相容性問題）。
- 轉移一律 `atomic_compare_exchange_strong`；讀取用 `memory_order_acquire`，寫入用 `memory_order_release`。
- 另有一個 `owner` 旗標（`OURS` / `FOREIGN`），只在 `INITIALIZING` 期間寫、`RUNNING` 之後唯讀，用來決定 `pm_shutdown` 要不要配對 `hs_exit`。
- **`INITIALIZING` 是短暫但可見的狀態**：輸掉競爭的執行緒會看到它。作法是**有界自旋 ＋ 讓出**（Windows `SwitchToThread`／POSIX `sched_yield`），等對方離開 `INITIALIZING` 再回報結果——這樣輸家拿到的是確定的答案，而不是一個「還沒好」的競態值。庫不因此開任何執行緒（C2.4）。

### 2. `pm_init_ex` 的三條路徑

```
pm_init_ex(cfg):
  1  驗證 cfg（純函數，無副作用）             失敗 → PM_ERR_ARGS，狀態不動
  2  CAS UNINIT → INITIALIZING                失敗 → 依現況回 PM_ERR_STATE
  3a 若 n_capabilities == 0（RTS 未起）：
        argv = {"particle-magic-ffi"}
        conf = defaultRtsConfig
        conf.rts_hs_main       = HS_BOOL_FALSE
        conf.rts_opts_enabled  = RtsOptsIgnoreAll        // E2-15
        conf.rts_opts          = 由 cfg 生成的字串（見下）
        hs_init_ghc(&argc, &argv, conf);  owner = OURS;  rc = PM_OK
  3b 否則（RTS 已由宿主啟動）：
        hs_init(&argc, &argv);                            // 只為配對 refcount
        若 cfg->capabilities != 0 → setNumCapabilities(解析後的值)   // 生效
        owner = FOREIGN
        rc = (nursery_bytes != 0 || gc_mode != PM_GC_DEFAULT
              || (stats == PM_STATS_ON && !getRTSStatsEnabled())) ? PM_ERR_STATE : PM_OK
  4  狀態 = RUNNING（release），回 rc
```

**`rts_opts` 字串由庫自己生成**，不接受宿主的任何自由文字（E2-5 說明理由：壞字串等於殺進程）。生成規則：

| `PmConfig` 欄位 | 生成的片段 | 依據 |
|---|---|---|
| `capabilities == 0` | `-N` | E2-6：`-N` 不帶數字＝依硬體；`-N0` 會殺進程 |
| `capabilities == 1` | （不加）| 與今天的預設逐位元相同 |
| `capabilities >= 2` | `-N<n>` | E2-2 |
| `nursery_bytes == 0` | （不加）| RTS 預設 4 MiB |
| `nursery_bytes > 0` | `-A<bytes>` | E2-7：純數字＝位元組 |
| `gc_mode == PM_GC_NONMOVING` | `--nonmoving-gc` | E2-2 |
| `stats == PM_STATS_ON` | `-T` | E4-1：`RtsConfig.rts_opts` 是這條路唯一可行的通道——`GHCRTS` 已被 `RtsOptsIgnoreAll` 關掉（E2-15／E4-3），`-with-rtsopts` 是 ADR-022 否決的替代方案，`defaultsHook` 直寫 `RtsFlags` 是私有 ABI（E2-4） |
| `stats == PM_STATS_OFF` | （不加）| E4-4：與今天的 `pm_init` 逐位元相同 |

字串以固定大小的堆疊緩衝組成（上限可靜態算出，欄位都是有界整數），不配置堆積。

**統計旗標與 F011 的交界**（本功能只做左半邊）：

| 誰 | 負責什麼 |
|---|---|
| F003（本功能） | `PmConfig.stats` 這個開關、它變成 `-T`、以及「要求了但開不起來就回 `PM_ERR_STATE`」 |
| F011 diagnostics-stats | `pm_stats`／`PmStats` 本身。判準寫死一句：**`getRTSStatsEnabled()` 為假時，進程層級的 GC 欄位一律回報為「不可用」**（`PmStats` 自己的旗標欄或哨兵值由 F011 定），**不得**把 `getRTSStats()` 回來的 `gc_elapsed_ns == 0` 當成真實數字——E4-2 證明那兩件事在關掉統計時長得一樣 |

**驗證規則與錯誤碼情境表**（`PM_ERR_ARGS` 的每一條都在 RTS 之前擋下，狀態與 RTS 皆不變）：

| 情境 | 回傳 | 副作用 |
|---|---|---|
| `config == NULL` | `PM_ERR_ARGS` | 無 |
| `size` 不是本庫認得的版本（v1 ＝ `sizeof(PmConfig)`） | `PM_ERR_ARGS` | 無。**大於也拒收**：宿主要求了本庫看不懂的欄位，靜默忽略就違反 C2.4 |
| `capabilities > PM_MAX_CAPABILITIES` | `PM_ERR_ARGS` | 無（E2-8：RTS 會照收並放大 capability 陣列，那不是宿主要的） |
| `nursery_bytes != 0` 且 `< PM_NURSERY_MIN_BYTES` 或 `> PM_NURSERY_MAX_BYTES` | `PM_ERR_ARGS` | 無（E2-7） |
| `gc_mode` 不是 `PM_GC_DEFAULT`／`PM_GC_NONMOVING` | `PM_ERR_ARGS` | 無 |
| `stats` 不是 `PM_STATS_OFF`／`PM_STATS_ON` | `PM_ERR_ARGS` | 無 |
| 狀態 `UNINIT`、RTS 未起（正常路徑 3a） | `PM_OK` | RTS 以四項設定啟動；狀態 `RUNNING`（`OURS`） |
| 狀態 `UNINIT`、RTS 已由宿主啟動、只要求 capabilities 或全預設（3b） | `PM_OK` | `setNumCapabilities` 生效；狀態 `RUNNING`（`FOREIGN`） |
| 同上，但要求 nursery、nonmoving GC，或要求統計而該進程的 RTS 沒開（3b 降級） | `PM_ERR_STATE` | capabilities **仍生效**；nursery／GC／統計**未套用**；狀態 `RUNNING`（`FOREIGN`），**庫可用**。要求統計而宿主的 RTS **本來就開著**（`getRTSStatsEnabled()` 為真）不算降級，回 `PM_OK` |
| 狀態 `INITIALIZING`（另一執行緒正在初始化） | `PM_ERR_STATE`（等對方離開該狀態後才回） | 無；本次設定未生效 |
| 狀態 `RUNNING`（重複初始化） | `PM_ERR_STATE` | 無；本次設定未生效（E2-10 的靜默忽略被擋在這裡） |
| 狀態 `CLOSED`（`pm_shutdown` 之後） | `PM_ERR_STATE` | 無。**永遠不會走到 `hs_init_ghc`**，所以 E1-4／E3-4 的死法不再可能 |

**`PM_ERR_STATE` 有兩種語氣**，標頭必須寫清楚：「呼叫順序錯，什麼都沒發生」與「庫已就緒，但你的部分設定在此進程無法生效」。宿主要分辨很簡單——後者只可能發生在**自己的第一次** `pm_init_ex` 上。

### 3. `pm_init` / `pm_shutdown` 的新語意

`pm_init`（凍結簽名 `void`，不動）：

| 狀態 | 今天 | 之後 |
|---|---|---|
| `UNINIT` | `hs_init`，單 capability、預設 GC | 走同一具狀態機的 3a，`rts_opts = NULL`，**單 capability、預設 GC 不變** |
| `RUNNING` | 冪等，無操作 | 同 |
| `CLOSED` | **殺進程**（E1-4） | 無操作。之後所有符號回 `PM_ERR_STATE` |
| RTS 已由宿主啟動 | `hs_init` 加 refcount | 同（3b，但沒有設定可套用） |

契約卡的「行為不變」指的是**成功路徑的可觀測行為**（單 capability、預設 GC、冪等）。兩處差異都是把未定義行為變成有定義：`CLOSED` 不再殺進程；`GHCRTS` 不再能蓋過或殺掉（E2-14 今天對 `pm_init` 成立）。兩者都寫進標頭與整合指南。

`pm_shutdown`（凍結簽名 `void`，不動）：

| 狀態 | 行為 |
|---|---|
| `RUNNING` | 先把狀態改成 `CLOSED`（release），**再**呼叫一次 `hs_exit()`——順序很重要：狀態先關，其他執行緒即使正在進閘門也只會拿到 `PM_ERR_STATE` |
| `UNINIT` / `CLOSED` | 無操作。**絕不**呼叫 `hs_exit`（E2-12 的 `too many hs_exit()s` 警告永遠不會出現） |
| `INITIALIZING` | 等對方離開後依上表處理 |

**兩平台語意一致的來源是狀態機，不是 RTS**：`CLOSED` 之後庫拒絕服務，與 RTS 到底停了沒有無關。因此 C2.5 的「Windows `DllMain` refcount 不對稱由實作吸收」自動成立——而且依 E1-2 的查證，Windows 根本沒有那個不對稱。`hs_exit` 只呼叫我們自己 `hs_init*` 過的次數（正好一次），所以宿主自己的 RTS 不會被我們關掉。

### 4. I3 的閘門：放在哪一層、成本多少

**必須在 C 側**，這是查證結論而非偏好：E1-2／E1-5／E3-2 顯示崩潰發生在 stub 進入 RTS 時（`newBoundTask`），Haskell 本體一行都沒跑到。所以：

1. `src/ffi/Magic/FFI.hs` 的 29 個匯出改用**具名外部符號**：`foreign export ccall "pm_hs_advance" pm_advance :: …`。Haskell 函式名、簽名、本體**全部不動**——只有生成的 C 符號名改變，因此 in-process 測試（呼叫 Haskell 函式）零影響。
2. 新增 `cbits/pm_gate.c`，以 `#include "particle_magic.h"` 取得公開原型，為每個公開符號寫一個三行的閘門：

```c
void pm_advance(PmSpell* s, float dt) {
    if (!pm_runtime_ready()) return;      /* acquire load + compare */
    pm_hs_advance(s, dt);
}
```

3. `pm_hs_*` **不進標頭、不進 `.def`**，所以 Windows 的匯出面一個位元不變；Linux 的 `.so` 會多出 29 個可見符號（`.so` 本來就把 RTS 全部符號都露出來，見 E3-1），標頭明文標示它們是內部符號。

**哨兵表**（`pm_runtime_ready()` 為假時的回傳；與 F001 的防火牆哨兵同構，只是值從 −6 換成 −7）：

| 回傳型別 | 符號 | 數量 | 哨兵 |
|---|---|---|---|
| `int`（計數／錯誤碼） | `pm_max_particles`、`pm_cast_ex`、`pm_is_finished`、`pm_observe`、`pm_observe_ex`、`pm_scene_*`（8 個）、`pm_spell_bounds`、`pm_spell_box`、`pm_emitter_count`、`pm_emitter_box`、`pm_occupancy`、`pm_scene_spell_bounds`、`pm_project`、`pm_depth_order` | 19 | `PM_ERR_STATE`（−7） |
| `PmSpell*` / `PmScene*` | `pm_cast`、`pm_scene_new` | 2 | `NULL`（`pm_cast` 另把一句固定 ASCII 訊息寫進 `err_buf`，長度有界、NUL 結尾） |
| `void` | `pm_advance`、`pm_free`、`pm_scene_free`、`pm_scene_dismiss`、`pm_scene_advance` | 5 | 直接返回 |
| `double` | `pm_age` | 1 | `-7.0`（比照 F001 的 `-6.0`；年齡恆非負，負值無歧義） |
| `uint32_t` | `pm_occupancy_mask` | 1 | `0`（fail-safe：回報「哪裡都沒有」） |
| `int`，但先於 RTS | `pm_abi_version` | 1 | **閘門不擋**：C 側直接回標頭的 `PM_ABI_VERSION`，任何狀態下都答得出來（見 A2） |

`pm_is_finished` 回 −7 在 C 側是 truthy，宿主的 `while (!pm_is_finished(s))` 會結束而不是空轉——與 F001 對 −6 的觀察同一條理由。

**成本**：單執行緒每次呼叫多一次 `atomic_load_explicit(memory_order_acquire)`（x86 上就是一道 `mov`）、一次比較、一次直接跳轉。相對於後面那個 C→Haskell 的 stub 呼叫（要建 bound task、進 RTS）是可忽略的量級。**這一層是每個符號都付的成本**，所以不做任何額外的事：不記錄、不上鎖、不查表。

### 5. 逐平台文件化

C2.4 要求「文件逐平台明列哪些欄位生效——不靜默忽略」。落點兩處：

1. `include/particle_magic.h`：`PmConfig` 上方的散文附「查證結果」那張表（哪個平台、哪個欄位、生效與否，四個欄位各一欄），並明說降級只在「RTS 已由宿主啟動」時發生、macOS 尚未實測。
2. `docs/integration.md` 新增「執行期」一節：狀態機圖、`pm_init_ex` 的遊戲建議設定、逐平台生效表、**「想要 GC 統計就必須在初始化時要求，事後補不了」**這句、關閉語意（含「長駐宿主乾脆別呼叫 `pm_shutdown`」的既有建議，理由從「RTS 不能重啟」升級為「狀態機會永久拒絕」）、`PM_ERR_STATE` 的兩種語氣。`docs/integration.md:447-451` 的既有四條要同步改寫。

### 6. 標頭、`.def`、C# 綁定

三方對帳的既有守門（`test/FFIContractSpec.hs`、`test/BindingContractSpec.hs`）決定了改動的形狀：

- 標頭：加 `PmConfig`、五個 `#define`、`pm_init_ex` 宣告。既有 31 條宣告與 `PM_ABI_VERSION` 不動。
- `.def`：`EXPORTS` 加一行 `pm_init_ex`（`particle-magic-ffi.def:8-38` 的 31 行不動）。
- `test/FFIContractSpec.hs:62` 的 `cbitsEntries` 從 `["pm_init","pm_shutdown"]` 變成 `["pm_init","pm_init_ex","pm_shutdown"]`，而 `:66` 的「標頭 ＝ Haskell 匯出 ＋ RTS pair」那條**模型要換**：閘門把公開符號全部搬進 C，所以新的等式是

  ```
  headerFunctions ≡ cbits 定義的公開符號 ≡ .def 的 EXPORTS
  foreignExports  ≡ { "pm_hs_" ++ name | name ← headerFunctions \ {pm_init, pm_init_ex, pm_shutdown} }
  ```

  `pm_abi_version` 也保留它的 `pm_hs_abi_version`（雖然閘門層自己就回答得出來），這樣等式沒有例外，而且多一條可斷言的等價：C 端回的值必須等於 Haskell 端回的值。

  這條新等式同時是「新符號不准漏掉閘門」的守門（F005 的三個符號因此自動納管）。
- `test/FFIContractSpec.hs:271-281` 的 `foreignExports` 剖析器要能處理具名外部符號（`foreign export ccall "pm_hs_x" x`）：取**引號內**的字串當 C 名、第五個字當 Haskell 名。**F001 的 T5 守門測試用的是同一個剖析手法**，合併時必須一起改（見「9. 合併順序」）。
- C# 綁定：`pm_init_ex` 的 `DllImport`（參數為 `ref PmConfig` 或 `IntPtr`）、對應的 `[StructLayout(LayoutKind.Sequential)] struct PmConfig`，以及五個 `public const int`（行尾註解必須帶巨集名，`BindingContractSpec` 是用它當鍵做雙向集合相等的）。

### 7. 與平行取樣門檻的關係（不改核心）

`src/core/Magic/Particle/Analytic.hs:394-399` 的 `sample` 在 `windowRows >= parallelThreshold`（8192）時走 `fillParallel`。單 capability 下那條路徑要付分片、`Strategies` 排程與最終串接的成本，卻拿不到任何加速——**今天出貨的 C 宿主每一幀都在付這個錢**。

本功能**不動核心一個位元**（門檻是 `particle-simulation` 的事，且 ADR-0017「law 2」保證兩條路徑逐位元相同，所以這純粹是成本問題不是正確性問題）。本功能做的是把決定權交出去，並把關係寫進文件：

- `pm_init_ex(capabilities >= 2)`（或 `0` ＝ 依硬體）才讓 8192 粒以上的分片路徑有意義；
- 只跑小陣（< 8192 粒）的宿主，`capabilities = 1` 與多 capability 沒有差別；
- ADR-0017 的「foreign library 的能力數留給 C ABI 決定」在此兌現。

整合指南的建議設定寫成一句可抄的話：**遊戲宿主通常要的是 `capabilities = 2..4`，而不是 `0`**——把整台機器的核心都拿去給粒子取樣，會跟引擎自己的 job system 搶時間片（ADR-022「考慮過的替代方案」第一條）。

### 8. 測試怎麼跑得起來（in-process 的限制）

hspec 套件是一個 Haskell 執行檔，**它的 RTS 一開始就是起來的**，所以：

- 測試進程裡 `n_capabilities != 0`，`pm_init_ex` 走的永遠是 **3b（`FOREIGN`）**那一支。這反而是好事：降級條款、`setNumCapabilities` 生效、以及「nursery／GC 回 `PM_ERR_STATE`」全部可以在 CI 的兩個平台上機械驗證。
- **3a（`OURS`）那一支 in-process 永遠測不到**。它的覆蓋是：實作期在 Windows 與 WSL 各跑一次本文件「平台查證」用的同一組探測（純 C 宿主 ＋ 真實產物），並由 **F006 oop-load-smoke** 機械化。本文件不把它算成自己的綠燈，見 A3。
- 要讓 hspec 呼叫得到 C 側的閘門與狀態機，`test-suite spec` 必須加 `c-sources: cbits/pm_init.c, cbits/pm_gate.c`（今天只有 foreign-library 有，`particle-magic.cabal:239`）。測試以 `foreign import ccall` 取用 `pm_init_ex`／`pm_init`／`pm_shutdown` 與幾個閘門符號。
- **`pm_shutdown` 在測試進程裡是單向門**：一旦呼叫，該進程的閘門就永遠回 `PM_ERR_STATE`。因此所有狀態機測試集中在**單一模組 `FFIRuntimeSpec`**、依 hspec 的宣告順序排列，關閉相關的斷言放**最後**。其他測試模組呼叫的是 Haskell 函式（不經閘門），不受影響。
- `hs_exit` 的安全性：測試進程的 refcount 是 main 的 1 ＋ 我們的 1；`pm_shutdown` 減一之後 RTS 仍然活著（E2-11 實測），測試不會自殺。
- `setNumCapabilities` 會改到測試進程的 capability 數。ADR-0017 law 2 保證輸出與核心數無關，所以安全；測試取「目前值 +1」並在斷言後不還原（RTS 不支援真正的還原，`enabled_capabilities` 可降但 `n_capabilities` 不降）。

### 9. 合併順序

| 情境 | 要做什麼 |
|---|---|
| **F001 先合**（正常順序） | 本功能直接用 `PM_ERR_STATE`／`pmErrState`；把 29 個 `foreign export` 改成具名形式時，**F001 的 T5 守門測試（動態列舉 `foreign export ccall <name>` 再檢查該定義塊有無 `firewall`）會因為抓到帶引號的字串而失效**——本功能負責把那個剖析器一起改成「有引號時取第五個字當 Haskell 名」。兩者的巢狀關係是：C 閘門（外）→ Haskell 防火牆（中）→ 本體（內），語意上互不干擾 |
| **本功能先合** | F001 合併時只需在既有本體上加組合子；它的剖析器要一開始就寫成能處理具名形式 |
| **F005 先合／後合** | 三個新符號各要一個閘門包裝與一行 `pm_hs_*` 重新命名；「新符號自動納管」的等式（見 6）會在漏做時亮紅燈 |
| **F002** | 不相交 |

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `PM_EXPORT void pm_init(void);` / `PM_EXPORT void pm_shutdown(void);`（`PM_EXPORT` ＝ `__declspec(dllexport)`／`__attribute__((visibility("default")))`） | `cbits/pm_init.c:33-34, 40-59` | - | 本功能改寫其實作；簽名與匯出屬性不動 |
| `static int pm_rts_running = 0;` | `cbits/pm_init.c:38` | - | 被原子狀態機取代（委派決策：裸 int 要換掉） |
| `void pm_init(void);` / `void pm_shutdown(void);`（標頭宣告） | `include/particle_magic.h:164, 167` | - | 凍結宣告；`pm_init_ex` 加在其後 |
| `#define PM_OK 0` / `#define PM_ERR_ARGS (-4)` | `include/particle_magic.h:114, 118` | - | `pm_init_ex` 的參數驗證回傳 `PM_ERR_ARGS`；成功回 `PM_OK` |
| `#define PM_ERR_STATE (-7)`、`pmErrState :: CInt`、`Pm.ErrState` | `include/particle_magic.h`／`src/ffi/Magic/FFI.hs`／`bindings/csharp/ParticleMagic.cs`（尚未實作） | **F001** | 本功能定義它在初始化／關閉／未初始化呼叫每個情境下的語意 |
| `#define PM_ABI_VERSION 1` | `include/particle_magic.h:98` | - | 閘門層的 `pm_abi_version` 直接回它（A2） |
| `extern void hs_init (int *argc, char **argv[]);` | `$(ghc --print-libdir)/…/rts-1.0.3/include/HsFFI.h:101` | - | 3b 路徑的 refcount 配對 |
| `void hs_init_ghc (int *argc, char **argv[], RtsConfig rts_config);` | `$(ghc --print-libdir)/…/rts-1.0.3/include/RtsAPI.h:311-312` | - | 3a 路徑：帶設定啟動 RTS |
| `extern const RtsConfig defaultRtsConfig;` | `RtsAPI.h:130` | - | 設定基底；本功能只改 `rts_hs_main`、`rts_opts_enabled`、`rts_opts` 三欄 |
| `typedef struct { RtsOptsEnabledEnum rts_opts_enabled; HsBool rts_opts_suggestions; const char *rts_opts; HsBool rts_hs_main; … void (*defaultsHook)(void); … } RtsConfig;` | `RtsAPI.h:83-125` | - | 同上；`defaultsHook` 經評估後**不採用**（E2-4：`RtsFlags` 是私有 ABI，且 0 值會 segfault） |
| `typedef enum { RtsOptsNone, RtsOptsIgnore, RtsOptsIgnoreAll, RtsOptsSafeOnly, RtsOptsAll } RtsOptsEnabledEnum;` | `RtsAPI.h:71-76` | - | 採用 `RtsOptsIgnoreAll`（E2-15） |
| `extern void hs_exit (void);` | `$(ghc --print-libdir)/…/rts-1.0.3/include/HsFFI.h:102` | - | `pm_shutdown` 的配對呼叫，最多一次 |
| `int getRTSStatsEnabled (void);` | `$(ghc --print-libdir)/…/rts-1.0.3/include/RtsAPI.h:284` | - | 3b 降級支判斷統計是否真的開著；測試的唯一判準；F011 的「不可用而非零」也用它 |
| `void getRTSStats (RTSStats *s);`（`typedef struct _RTSStats {…} RTSStats;` 含 `gcs`、`major_gcs`、`allocated_bytes`、`gc_elapsed_ns`、`nonmoving_gc_*` 等欄） | `$(ghc --print-libdir)/…/rts-1.0.3/include/RtsAPI.h:192-281, 283` | - | **本功能不呼叫**；列在此處是因為 E4-2 的行為（統計關閉時不崩、但時間欄位為零）是「回報不可用而非零」這條規則的依據，F011 會消費它 |
| `extern uint32_t n_capabilities;` | `$(ghc --print-libdir)/…/rts-1.0.3/include/rts/Threads.h:72` | - | 偵測「RTS 是否已被別人啟動」（E3-3：未啟動時為 0） |
| `INLINE_HEADER unsigned int getNumCapabilities(void) { return RELAXED_LOAD(&n_capabilities); }` | `rts/Threads.h:74-75` | - | 同上的具名讀取；亦供測試斷言 capability 數 |
| `extern void setNumCapabilities (uint32_t new_);` | `rts/Threads.h:92` | - | 3b 降級路徑讓 capability 數仍然生效（E2-9） |
| `uint32_t getNumberOfProcessors (void);` | `rts/OSThreads.h:253` | - | `capabilities == 0` 時的說明用途與測試斷言；生成字串用的是 `-N`（不帶數字），不自己算 |
| `foreign export ccall pm_advance :: StablePtr SpellCell -> CFloat -> IO ()`（29 個匯出的代表） | `src/ffi/Magic/FFI.hs:336, 341, 353, 386, 432, 441, 451, 461, 520, 662, 680, 693, 702, 746, 848, 859, 869, 925, 939, 946, 974, 991, 1012, 1020, 1057, 1083, 1092, 1126, 1181` | - | 逐一改為具名外部符號 `"pm_hs_*"`；Haskell 函式名、簽名、本體不動 |
| `pm_abi_version :: IO CInt` / `pm_abi_version = pure pmAbiVersion` | `src/ffi/Magic/FFI.hs:336-339` | - | 保留為 Haskell 函式（in-process 測試用），但公開符號改由 C 端回答 |
| `EXPORTS` 清單（31 行） | `particle-magic-ffi.def:7-38` | - | 加一行 `pm_init_ex`；既有 31 行不動 |
| `foreign-library particle-magic-ffi` 的 `c-sources: cbits/pm_init.c`、`include-dirs: include`、`ghc-options: -Wall -O2 -threaded` | `particle-magic.cabal:230-247` | - | 加 `cbits/pm_gate.c`；**不加 `-with-rtsopts`**（那正是 ADR-022 否決的替代方案） |
| `test-suite spec` 的 `hs-source-dirs: test, app, src/ffi, tools` | `particle-magic.cabal:249-262` | - | 加 `c-sources`，讓 hspec 能呼叫 C 側狀態機與閘門 |
| `cbitsEntries :: [String]` / `cbitsEntries = ["pm_init", "pm_shutdown"]` | `test/FFIContractSpec.hs:61-62` | - | 加入 `pm_init_ex`；三方對帳的模型改版 |
| `foreignExports :: IO [String]`（剖析 `foreign export ccall <name>`） | `test/FFIContractSpec.hs:271-281` | - | 改為能處理具名外部符號 |
| `headerFunctions :: IO [String]` | `test/FFIContractSpec.hs:283-299` | - | 新宣告 `int pm_init_ex(const PmConfig* config);` 自動被納入三方對帳（`typedef` 那行會被剖析器排除） |
| `headerDefines :: IO [(String, Int)]` | `test/FFIContractSpec.hs:314-333` | - | 五個新 `#define` 進入標頭 ↔ C# 的雙向對帳 |
| `defExports :: IO [String]` | `test/FFIContractSpec.hs:301-312` | - | `.def` ↔ 標頭 的集合相等 |
| `readUtf8 :: FilePath -> IO String` | `test/FFIContractSpec.hs:351-357` | - | 新測試讀標頭與 `docs/integration.md` |
| `it "mirrors every header constant, by name and by value"`（雙向集合相等，鍵為 C# 行尾註解的巨集名） | `test/BindingContractSpec.hs:41-48` | - | 五個新 `#define` 必須同步 C# 常數 |
| `it "declares exactly the header's entry points, no more and no fewer"` | `test/BindingContractSpec.hs:31-34` | - | `pm_init_ex` 必須有 `DllImport` |
| `testCtx :: CastContext` / `spellBytes :: FilePath -> IO BS.ByteString` / `castOk :: BS.ByteString -> CastContext -> IO (StablePtr SpellCell)` | `test/FFIHarness.hs:71, 80, 111` | - | 閘門測試要在「初始化前後」各跑一次真實生命週期，證明合法路徑不受影響 |
| `parallelThreshold :: Int` / `parallelThreshold = 8192` | `src/core/Magic/Particle/Analytic.hs:495-496` | - | **只讀不改**：文件說明 capability 數與這個門檻的關係 |
| `sample :: CompiledSpell -> CastContext -> Time -> ParticleBuffer`（`windowRows < parallelThreshold` 時走 `fillSequential`，否則 `fillParallel`） | `src/core/Magic/Particle/Analytic.hs:394-399` | - | 同上 |
| `docs/integration.md` §4.4 生命週期規則四條 | `docs/integration.md:445-451` | - | 改寫為狀態機語意；`:450` 的「RTS 不能重啟」升級為「狀態機永久拒絕，且不再殺進程」 |

## 新增的介面

### C 面（`include/particle_magic.h`，只加不改）

```c
/* GC mode for PmConfig.gc_mode. */
#define PM_GC_DEFAULT 0      /* the runtime's copying collector */
#define PM_GC_NONMOVING 1    /* mark-and-sweep oldest generation: shorter pauses */

/* Runtime statistics for PmConfig.stats. The runtime can only be told to
   collect them WHILE STARTING UP, so a host that wants pm_stats to answer
   the process-wide GC numbers has to say so here. Without it those
   numbers are reported as unavailable -- not as zero, which is what the
   runtime itself would hand back and is indistinguishable from "no GC
   pauses happened". */
#define PM_STATS_OFF 0
#define PM_STATS_ON 1

/* Bounds pm_init_ex validates PmConfig against. Outside them it answers
   PM_ERR_ARGS and starts nothing -- the runtime would otherwise abort the
   whole process on a bad value. */
#define PM_MAX_CAPABILITIES 256
#define PM_NURSERY_MIN_BYTES 8192
#define PM_NURSERY_MAX_BYTES 1073741824

/* Runtime settings. Zero the whole struct, set size to sizeof(PmConfig),
   fill in what you care about. Add-only: a later ABI generation may add
   fields at the end, and `size` is how this library knows which ones you
   compiled against. */
typedef struct PmConfig {
    uint32_t size;           /* sizeof(PmConfig) */
    uint32_t capabilities;   /* 0 = follow the hardware; else 1..PM_MAX_CAPABILITIES */
    uint64_t nursery_bytes;  /* 0 = the runtime's default (4 MiB) */
    uint32_t gc_mode;        /* PM_GC_* */
    uint32_t stats;          /* PM_STATS_* -- can only be decided here */
} PmConfig;

/* Start the runtime with the host's settings. Call it INSTEAD of pm_init,
   once, before anything else.

   Returns PM_OK, PM_ERR_ARGS (the config is out of range -- nothing was
   started), or PM_ERR_STATE, which means one of two things: the call was
   out of order (already initialised, or after pm_shutdown -- nothing
   happened), or the runtime was already running in this process before
   the library was asked, so the capability count took effect but the
   nursery, the GC mode and the statistics flag could not. Which fields
   take effect on which platform is the table above. */
int pm_init_ex(const PmConfig* config);
```

- 版面：`4 + 4 + 8 + 4 + 4 = 24` 位元組，三個 Tier 1 ABI 上皆無填充、`sizeof(PmConfig) == 24`。`stats` 佔的正是初版預留給 `reserved` 的那個槽——**v1 尚未出貨**，所以這是改欄位而不是加欄位，`size` 仍是 24，日後要再加欄位一樣往尾端長。
- 散文另附：查證出來的**逐平台生效表**（含 RTS 統計那一欄）、狀態機四態、`PM_ERR_STATE` 的兩種語氣、閘門哨兵表（未初始化／已關閉時各類回傳值）、「`pm_shutdown` 之後本進程不得再使用本庫」這句承諾，以及供 F011 消費的那條判準：**統計未啟用時，進程層級的 GC 數字回報為不可用，不是零**。
- `PM_ABI_VERSION` 不動；既有 31 條宣告不動。

### C 側內部（`cbits/`，不進標頭）

| 名稱 | 說明 |
|---|---|
| `cbits/pm_init.c` | 狀態機、`pm_init`、`pm_init_ex`、`pm_shutdown`、設定驗證與 `rts_opts` 字串生成 |
| `cbits/pm_gate.c` | 29（＋F005 的 3）個閘門包裝；`#include "particle_magic.h"` 取原型 |
| `pm_runtime_ready()`（內部連結或 `cbits` 內共用） | 一次 acquire 讀取 ＋ 比較；閘門的唯一判斷 |
| `pm_hs_*` | 29 個 Haskell 匯出的新外部符號名。**內部**：不進標頭、不進 `.def`；Linux 的 `.so` 會看得到（`.so` 本來就露出全部符號） |

### Windows 匯出（`particle-magic-ffi.def`）

`EXPORTS` 加一行 `pm_init_ex`。`pm_hs_*` 不加。

### C# 面（`bindings/csharp/ParticleMagic.cs`）

| 名稱 | 說明 |
|---|---|
| `[StructLayout(LayoutKind.Sequential)] public struct PmConfig` | 五個欄位（`size`、`capabilities`、`nursery_bytes`、`gc_mode`、`stats`），型別對應 `uint/uint/ulong/uint/uint` |
| `public static extern int pm_init_ex(ref PmConfig config);` | 帶 `[DllImport("particle-magic-ffi")]` |
| `Pm.GcDefault`、`Pm.GcNonmoving`、`Pm.StatsOff`、`Pm.StatsOn`、`Pm.MaxCapabilities`、`Pm.NurseryMinBytes`、`Pm.NurseryMaxBytes` | 七個 `public const int`，行尾註解必須帶巨集名 |

## TodoList

- [x] T1: `include/particle_magic.h` 加 `PmConfig`（含 `stats` 欄）、七個 `#define`、`pm_init_ex` 宣告，以及逐平台生效表（含 RTS 統計欄）／狀態機／`PM_ERR_STATE` 兩種語氣／閘門哨兵表的散文；`PM_ABI_VERSION` 與既有 31 條宣告不動 `dep: F001`
- [x] T2: `cbits/pm_init.c` 換掉裸 `static int`，實作四態原子狀態機（C11 atomics、CAS、acquire／release、`INITIALIZING` 的有界自旋讓出）與 `owner` 旗標 `dep: -`
- [x] T3: 實作 `PmConfig` 驗證（`NULL`／`size`／`capabilities`／`nursery_bytes`／`gc_mode`／`stats`）與 `rts_opts` 字串生成（`-N`／`-N<n>`／`-A<bytes>`／`--nonmoving-gc`／`-T`，堆疊緩衝、零堆積配置） `dep: T2`
- [x] T4: 實作 `pm_init_ex` 的三條路徑：3a（`hs_init_ghc` ＋ `RtsOptsIgnoreAll`）、3b（refcount 配對 ＋ `setNumCapabilities` ＋ 降級回 `PM_ERR_STATE`）、以及狀態不對時的 `PM_ERR_STATE` `dep: T3`
- [x] T5: 改寫 `pm_init`（`CLOSED` 不再殺進程、走同一具狀態機、成功路徑行為不變）與 `pm_shutdown`（先改狀態再 `hs_exit`，只配對我們自己的初始化，`UNINIT`／`CLOSED` 為無操作） `dep: T4`
- [x] T6: `src/ffi/Magic/FFI.hs` 的 29 個 `foreign export ccall` 改為具名外部符號 `"pm_hs_*"`；Haskell 函式名、簽名、本體不動 `dep: -`
- [x] T7: 新增 `cbits/pm_gate.c`：29 個閘門包裝依哨兵表回值；`pm_abi_version` 由 C 端直接回 `PM_ABI_VERSION`；`pm_cast` 的閘門另寫固定 ASCII 訊息進 `err_buf` `dep: T2, T6`
- [x] T8: `particle-magic.cabal`：foreign-library 加 `cbits/pm_gate.c`；`test-suite spec` 加 `c-sources: cbits/pm_init.c, cbits/pm_gate.c`；新測試模組登記進 `other-modules` `dep: T7`
- [x] T9: `particle-magic-ffi.def` 加 `pm_init_ex`；`test/FFIContractSpec.hs` 的三方對帳改版（`cbitsEntries`、新等式、`foreignExports` 剖析器支援具名形式） `dep: T7`
- [x] T10: `bindings/csharp/ParticleMagic.cs` 加 `PmConfig` 結構（含 `stats`）、`pm_init_ex` 的 `DllImport` 與七個常數（行尾註解帶巨集名） `dep: T1`
- [x] T11: `docs/integration.md` 新增「執行期」一節（狀態機、`pm_init_ex` 建議設定與 capability／`parallelThreshold` 的關係、逐平台生效表、RTS 統計只能在初始化時表態、關閉語意），並改寫 §4.4 的四條生命週期規則 `dep: T5`
- [x] T12: RTS 統計旗標端到端：`stats == PM_STATS_ON` → `rts_opts` 帶 `-T` → `getRTSStatsEnabled()` 為真；`PM_STATS_OFF`（與 `pm_init()`）維持統計關閉；降級支（RTS 已由宿主啟動且統計沒開）回 `PM_ERR_STATE` 而不是靜默忽略；並把「`getRTSStatsEnabled()` 為假時 GC 欄位一律不可用」這條判準寫進標頭，供 F011 消費 `dep: T4`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `FFIContractSpec` — `it "declares PmConfig, its bounds and the per-platform runtime table"` | 標頭含 `typedef struct PmConfig`、五個 `#define` 的值（`headerDefines`）、`pm_init_ex` 出現在 `headerFunctions`；散文含哨兵詞（如 `PM_GC_NONMOVING` 與平台表的標記字串）；`PM_ABI_VERSION` 仍為 1 |
| T2 | `FFIRuntimeSpec` — `it "refuses a second initialisation instead of silently ignoring it"` | 在測試進程（RTS 已起）呼叫一次 `pm_init_ex` 得 `PM_OK`／`PM_ERR_STATE`（依設定），再呼叫一次必得 `PM_ERR_STATE`；`pm_init()` 重複呼叫為無操作且不改變狀態 |
| T3 | `FFIRuntimeSpec` — `it "answers PM_ERR_ARGS for every out-of-range config and starts nothing"` | 表驅動走完錯誤碼情境表的六個 `PM_ERR_ARGS` 列（`NULL`、`size` 錯、`capabilities` 超界、`nursery_bytes` 過小／過大、`gc_mode` 未知、`stats` 未知），每一條之後狀態仍可被正常初始化 |
| T4 | `FFIRuntimeSpec` — `it "applies the capability count and reports the fields it could not honour"` | 以 `capabilities = getNumCapabilities() + 1`、`nursery_bytes = 0`、`gc_mode = PM_GC_DEFAULT` 呼叫 → `PM_OK` 且 `getNumCapabilities()` 變成要求值；另一組帶 `nursery_bytes`／`PM_GC_NONMOVING` → `PM_ERR_STATE`，但 capability 數仍生效、庫仍可用（隨後 `pm_cast` 成功） |
| T5 | `FFIRuntimeSpec` — `it "makes shutdown one-way, identically on Windows and Linux"`（本模組**最後**一條） | `pm_shutdown()` 後：`pm_init_ex` 回 `PM_ERR_STATE`、`pm_init()` 為無操作且不重啟、再次 `pm_shutdown()` 為無操作（不出現 `too many hs_exit()s`）、閘門符號全部回哨兵、**測試進程存活**到套件結束 |
| T6 | `FFIContractSpec` — `it "routes every C symbol through the gate and keeps the Haskell exports internal"` | 新等式：`headerFunctions` ≡ `.def` 的 `EXPORTS` ≡ `cbits` 定義的公開符號；且 `foreignExports` ≡ `pm_hs_` ＋（標頭符號扣掉 `pm_init`／`pm_init_ex`／`pm_shutdown` 三個 C 原生生命週期符號）；另斷言閘門的 `pm_abi_version` 與 `pm_hs_abi_version` 回同一個值。清單不寫死，F005 的新符號漏包閘門即紅 |
| T7 | `FFIRuntimeSpec` — `it "answers a sentinel instead of killing the process before init"` | 在 `pm_init*` 之前（測試模組最前面）表驅動呼叫閘門符號：`int` 類回 −7、`pm_cast`／`pm_scene_new` 回 `NULL`（且 `err_buf` 是 NUL 結尾的可讀 ASCII）、`void` 類安靜返回、`pm_age` 回 `-7.0`、`pm_occupancy_mask` 回 `0`、`pm_abi_version` 回 `1`；進程存活 |
| T8 | `FFIContractSpec` — `it "builds the foreign library and the test suite from the same C sources"` | foreign-library 的 `c-sources` 同時含 `cbits/pm_init.c` 與 `cbits/pm_gate.c`；`test-suite spec` 的 `c-sources` 亦然（沒有這一條，T7／T2 根本連結不起來） |
| T9 | `FFIContractSpec` — `it "exports through the Windows .def file exactly what the header declares"`（既有測試，須綠）＋ `cbitsEntries` 更新 | `.def` 少了 `pm_init_ex`、或多了 `pm_hs_*` 即紅 |
| T10 | `BindingContractSpec` — `it "mirrors every header constant, by name and by value"` 與 `it "declares exactly the header's entry points, no more and no fewer"`（既有測試，須綠） | 五個新 `#define` 與 `pm_init_ex` 在 C# 綁定缺席即紅 |
| T11 | `FFIRuntimeSpec` — `it "documents the runtime contract per platform in the integration guide"` | `docs/integration.md` 含「執行期」章節的哨兵字串：`pm_init_ex`、`PM_ERR_STATE`、`PM_STATS_ON`、逐平台表的標記、以及 capability 數與 8192 門檻關係的那一句；§4.4 不再宣稱重新初始化會怎樣而不說結果 |
| T12 | `FFIRuntimeSpec` — `it "only reports GC numbers when the host asked for statistics at init"` | 三段，全部以 `foreign import ccall "getRTSStatsEnabled"` 為判準（那正是 F011 會用的那一個）：**(a)** 在 RTS 已起、統計未開的測試進程裡以 `stats = PM_STATS_ON` 呼叫 `pm_init_ex` → 回 `PM_ERR_STATE`，且 `getRTSStatsEnabled()` 仍為 0——**要求了但不可用，而且沒有被靜默忽略**；**(b)** 以 `PM_STATS_OFF` 呼叫 → 回 `PM_OK`，統計維持關閉，`pm_init()` 亦然（E4-4 的回歸）；**(c)** 判準本身的守門：斷言標頭寫著「`getRTSStatsEnabled()` 為假時 GC 欄位不可用」那一句（哨兵詞 `PM_STATS_ON`），因為 `getRTSStats()` 在關閉時回的 `gc_elapsed_ns` 是 0 而不是錯誤（E4-2）。**「要求統計 → 真的拿得到 GC 數字」的正向端到端**只在 `OURS` 支成立，in-process 不可能（見 A1／A3）：實作期以 scratchpad 的純 C 探測在 Windows 與 WSL 各驗一次（E4-1 即該探測的輸出），機械化與 `pm_stats` 層級的斷言隨 F011／F006 落地 |

**併發（驗收標準第 4 條）**在 T2 的模組裡另有一條：`it "lets only one of two racing initialisations win"`——兩個 `forkIO` 同時呼叫 `pm_init_ex`，斷言恰好一個回 `PM_OK`（或在 `FOREIGN` 降級下的既定碼）、另一個回 `PM_ERR_STATE`，兩者都不崩，事後狀態為 `RUNNING`。它掛在 T2（狀態機）名下，因為原子性是 T2 的產物。

## 待確認假設

- **A1**: 契約卡要求「在 Linux 三者於 RTS 中實際生效（以 RTS 統計驗證）」，但查證顯示 in-process 的 hspec 永遠走降級支（測試進程的 RTS 已起），而 Windows 的 `.def` 又不匯出 `RtsFlags`／`n_capabilities`，純 C 宿主在 Windows 上讀不到 nursery、GC 模式與統計旗標 → 採取：hspec 驗證「capability 數生效」與「降級回 `PM_ERR_STATE`」兩件事（兩平台皆可）；「四者全生效」以本文件的 E2-2／E3-5／E4-1 為查證證據，並在實作期於 Windows 與 WSL 各跑一次同一組探測，機械化留給 F006（Linux 以 `dlsym("RtsFlags")`／`dlsym("getRTSStatsEnabled")` 斷言 nursery、GC 模式與統計，Windows 只斷言 capability 數與生命週期）→ 影響：若編排者要求 Windows 也能機械驗證 nursery，唯一的路是讓 `pm_stats`（F011）回報 RTS 旗標，那會改動 F011 的結構定義。
- **A2**: `pm_abi_version` 今天在 `pm_init` 之前呼叫會殺進程（E1-2），但標頭寫的是「startup 時比對」 → 採取：閘門層讓 `pm_abi_version` 由 C 端直接回 `PM_ABI_VERSION`（同一個標頭巨集，不是第二份真相），使它在任何狀態下都可安全呼叫；Haskell 的 `pm_abi_version` 保留給 in-process 測試 → 影響：若編排者認為「C 面不得比 Haskell 面多知道一件事」也涵蓋常數，就把它降級為一般閘門符號（未初始化回 −7），要改標頭那句與 T7 的期望值。
- **A3**: 「RTS 由我們啟動」那一支（3a）在 in-process 無法覆蓋 → 採取：本功能的綠燈不含它；實作期以純 C 探測在 Windows 與 WSL 各驗一次（產物不留 repo），機械化明文交給 F006 → 影響：若編排者要求本功能自帶 out-of-process 測試，等於把 F006 的 M8 工作提前，兩份文檔要重新分工。
- **A4（已由階段閘門裁決：推翻，現在就加）**: RTS 統計（`-T`）在初始化後無法再開，而 F011 diagnostics-stats 的「GC 次數與暫停時間」需要它。初版的判斷是「本功能不開、留給 F011 加欄位」；**編排者在階段閘門推翻，並已更新 C1.5／C1.8／ADR-022 D6 與本功能的契約卡** → 現行作法：`PmConfig` 的第四個欄位 `stats`（`PM_STATS_OFF`／`PM_STATS_ON`）現在就進 v1，對映到 `rts_opts` 的 `-T`（E4-1 實測在 `RtsOptsIgnoreAll` 之下可行），要求了但開不起來一律回 `PM_ERR_STATE`；判準交給 F011 的是 `getRTSStatsEnabled()`，不是欄位值（E4-2）。這條不再是待確認假設，留在此處只為記錄裁決。
- **A9**: 「要求統計時 `pm_stats` 拿得到 GC 數字」這句斷言跨了兩份文檔——`pm_stats` 是 F011 的符號，而正向路徑（RTS 由本庫啟動並帶 `-T`）in-process 測不到 → 採取：本功能的 1-to-1 測試以 `getRTSStatsEnabled()` 斷言「要求了但不可用時回 `PM_ERR_STATE`、未要求時維持關閉」，正向端到端以 E4-1 的純 C 探測為查證證據並在實作期於兩平台各跑一次；`pm_stats` 層級的「不可用而非零」由 F011 依標頭寫死的判準實作與斷言 → 影響：若編排者要求本功能自帶 `pm_stats` 層級的斷言，等於把 F011 的 `PmStats` 結構定義提前到這裡，兩份文檔要重新分工（建議維持現狀：本功能交開關，F011 交讀數）。
- **A10**: T12 的「要求統計但這個 process 開不起來 → `PM_ERR_STATE`」那一支 **in-process 不可達**——hspec 套件自己是以 `-with-rtsopts=-N -T` 建的（`particle-magic.cabal`：ExprCodeSpec 需要 `-T` 讀配置計數器），所以測試進程的 `getRTSStatsEnabled()` 本來就是真 → 採取：T12 改斷言錯誤碼情境表的**另一列**——「要求統計而宿主的 RTS 本來就開著，不算降級」——再加上「旗標在初始化之後永不改變」這個不變量；降級條款本身由同一次呼叫的 nursery 與 GC 模式觸發（那兩者在任何 in-process 進程都不可套用），所以 `rc` 的計算式仍被覆蓋 → 影響：若要機械覆蓋那一支，需要一個「RTS 已啟動但沒有 `-T`」的宿主進程；F006 的 out-of-process harness 走的是 3a（全新進程、RTS 未起），覆蓋不到，建議由 F011 隨 `pm_stats` 一起補一個小型 Haskell 宿主。
- **A11**: 併發驗收（標準第 4 條）在 in-process 只觀察得到「兩個都回 `PM_ERR_STATE`」——因為測試進程的每一次首次初始化都走降級支（3b），贏家也拿不到 `PM_OK` → 採取：兩條執行緒**要求不同的 capability 數**（N+1 與 N+2），事後斷言 `getNumCapabilities()` 恰為其中之一且不等於原值——這證明「只有一個真的碰到了 RTS」，比只看回傳碼更強；「贏家回 `PM_OK`」則由實作期兩平台的純 C 探測覆蓋（見實作備註 V1／V2） → 影響：若編排者要求 in-process 也看到 `PM_OK`，唯一的路是讓首次初始化不帶任何無法套用的欄位，代價是放棄 in-process 的降級覆蓋——而降級支只有 in-process 測得到（與 A10 同一條理由）。
- **A5**: `rts_opts_enabled = RtsOptsIgnoreAll` 讓 `GHCRTS` 環境變數對本庫完全失效（E2-13／E2-14：今天它能蓋過宿主設定，甚至殺進程） → 採取：`pm_init` 與 `pm_init_ex` 都用 `RtsOptsIgnoreAll`，理由是 P-1（庫永不殺宿主）與「RTS 是宿主的」——環境變數不是宿主的 API 呼叫 → 影響：若有人靠 `GHCRTS` 對出貨的庫做現場調校，那條路會消失；要保留就得改用 `RtsOptsSafeOnly` 並接受 E2-14 的殺進程風險（不建議），或加一個 `PmConfig` 欄位開放它。
- **A6**: `size` 大於本庫認得的版本時拒收（`PM_ERR_ARGS`）而非忽略多出來的欄位 → 採取：拒收，因為「不靜默忽略任何無法生效的設定」是契約卡明文 → 影響：未來新版標頭編出的宿主無法在舊版庫上跑，這是刻意的；若要改成「向前相容地忽略」，得同時定義一條「哪些欄位可以被安全忽略」的規則，那應該寫進 ADR 而不是這裡。
- **A7**: 閘門層讓 `pm_hs_*` 這 29 個內部符號、以及 `pm_runtime_ready`（兩個 C 翻譯單元共用狀態機的那一個問句）在 Linux 的 `.so` 上可見（Windows 因 `.def` 不可見；實測 Linux 匯出 32 個公開 `pm_*` ＋ `pm_runtime_ready` ＋ 29 個 `pm_hs_*`，Windows 匯出表正好 32 個） → 採取：接受並在標頭註明它們是內部符號、不屬於 ABI；不為此加 version script 或 `-fvisibility=hidden`（那會動到連結設定，屬 F007 packaging-content 的範圍） → 影響：若 F007 之後決定收斂 Linux 的匯出面，`pm_hs_*` 要一併隱藏，兩份文檔的守門測試要對齊。
- **A8**: `cbits` 使用 C11 `<stdatomic.h>` → 採取：三平台的 GHC 工具鏈皆支援，且 `cbits` 從不由 MSVC 編譯（MSVC 宿主只連結匯入庫）→ 影響：若日後有平台的工具鏈缺 C11 atomics，退路是平台一次性初始化原語（`InitOnceExecuteOnce`／`pthread_once`）加上 volatile 旗標，狀態機的外顯行為不變。

## 實作備註

### 與文件的偏差（逐條）

| # | 文件寫的 | 實作做的 | 為什麼 |
|---|---|---|---|
| D1 | 等式 `foreignExports ≡ { "pm_hs_" ++ name }` | `pm_hs_` ＋ **去掉 `pm_` 之後**的名字（`pm_advance` → `pm_hs_advance`） | 文件自己的範例就是後者，兩處互相矛盾；採可讀的那一個。守門測試以一個 `gatedName` 函數表達，清單仍不寫死 |
| D2 | `rts_opts` 用「固定大小的堆疊緩衝」 | 固定大小的 **static** 緩衝 | `hs_init_ghc` 會在 RTS 的生命週期內保留這個指標，堆疊緩衝離開 `pm_init_ex` 就失效。仍是零堆積配置，而且只有贏得 CAS 的執行緒寫得到它 |
| D3 | 只列了 `cbits/pm_init.c` 與 `cbits/pm_gate.c` | 另加內部標頭 `cbits/pm_runtime.h` | 兩個 C 翻譯單元要共用 `pm_runtime_ready()`。不安裝、不進標頭、不進 `.def`；Linux 的 `.so` 會多看到這一個符號（併入 A7） |
| D4 | 以 `extern uint32_t n_capabilities;` 自行宣告 | `#include "Rts.h"` 之後用 `getNumCapabilities()`／`setNumCapabilities()` | `RtsAPI.h` **不是自足的**（它用到 `W_`、`STG_NORETURN`），單獨 include 編不過。既然一定要 `Rts.h`，那兩個符號就用它給的具名讀寫，不再手寫 extern |
| D5 | T12 的 (a) 段 | 改成錯誤碼情境表的另一列 | 見 A10：測試進程本身帶 `-T` |
| D6 | 併發例「恰好一個回 `PM_OK`」 | 「恰好一個真的碰到了 RTS」（以兩個不同的 capability 請求觀察） | 見 A11 |
| D7 | T11 的守門掛在 `FFIRuntimeSpec` | `FFIRuntimeSpec` **與** `FFIContractSpec` 各一條 | 前者照 1-to-1 表，後者是這個專案放「剖析檔案的守門」的地方；兩條的哨兵字串不同，互為補強 |

### 既有測試的改動（三處，都是「加法造成的」而不是放寬）

1. `test/FFIContractSpec.hs` 的 ``length declared `shouldBe` 31`` → `32`（兩處）。標頭多了 `pm_init_ex` 一個宣告；凍結的意思是「名字不准離開、不准改形狀」，加入時這個數字本來就會動，和 func-spec 0018／0025 每一輪一樣。
2. 同檔 `sort (map fst defined)` 的巨集清單加入七個新 `#define`（`PM_GC_*`、`PM_STATS_*`、`PM_MAX_CAPABILITIES`、`PM_NURSERY_*`）。那條是雙向集合相等，不加就紅。
3. `test/FFIFirewallSpec.hs` 與 `test/FFIContractSpec.hs` 的 `foreign export` 剖析器改為接受具名形式（有引號時取第 5 個字當 Haskell 名）。這正是本文件「9. 合併順序」預告的那一項：F001 的 T5 守門（`length exports == 29` ＋ 每個匯出都在 `firewall` 裡）**照舊全綠**，它剖析的是同一批 29 個 Haskell 名字。`cbitsEntries` 由兩個變三個。

另外 `FFIRuntimeSpec` 對 `pm_max_particles` 的斷言比對的是 `Magic.FFI.pmMaxParticles`（今天是 16384）而不是字面量 4096：閘門的職責是**轉發**，4096 是凍結的標頭巨集、不是查詢的答案（func-spec 0011 §2 拆開的正是這兩者）。

### 實作期的機械查證（純 C 宿主，產物不留 repo）

3a（「RTS 由本庫啟動」）與 `PM_OK` 這兩件 in-process 測不到的事，依 A1／A3 在兩個平台各跑一次真實產物：

- **V1 — Windows，`LoadLibraryA` 驅動 `particle-magic-ffi.dll`**：全部檢查通過。初始化前 `pm_abi_version()` 回 1、`pm_max_particles()` 回 −7、`pm_cast` 回 `NULL` 並寫出可讀訊息、`void` 類安靜返回（**以前這些每一條都會殺掉進程**）；四項設定的 `pm_init_ex` 回 `PM_OK`；完整 cast→advance→observe→free；二次初始化回 −7；`pm_shutdown` 之後全部回哨兵、再 `pm_init_ex` 回 −7、再 `pm_shutdown` 無事，進程以 0 結束。DLL 匯出表**正好 32 個**（31 ＋ `pm_init_ex`），`GetProcAddress(h, "pm_hs_advance")` 為 `NULL`。
- **V2 — Linux（`wsl -d Debian`），`dlopen` 驅動 `libparticle-magic-ffi.so`**：同一套檢查全過，並且**四項設定逐一驗到 RTS 裡**（經相依鏈 `dlsym`）：初始化前 `n_capabilities == 0`、之後 `n_capabilities == 4`、`RtsFlags.GcFlags.minAllocAreaSize == 16384` blocks（＝ 64 MiB）、`useNonmoving == 1`、`getRTSStatsEnabled() == 1`。二次初始化回 −7 **且 `n_capabilities` 仍是 4**（設定真的沒被套用）。

驗收標準第 1 條（「四者在 RTS 中實際生效」）因此是機械驗過的，不再只是 E2／E3 的旁證。

### 兩平台測試結果

| 平台 | 結果 |
|---|---|
| Windows x86_64 | `cabal test` **1816 examples, 0 failures**（基線 1804 ＋ 12） |
| Linux x86_64（WSL Debian，GHC 9.14.1） | `cabal test` **1816 examples, 0 failures, 9 pending**（pending 是既有的平台相關項） |

新增的 12 條：`FFIRuntimeSpec` 8 條（T2／T3／T4／T5／T7／T11／T12 ＋ 併發）、`FFIContractSpec` 4 條（T1／T6／T8／T11）。

### 沒做的事（確認）

`PM_ABI_VERSION` 仍為 1；既有 31 條標頭宣告一個位元未動；`src/core/Magic/Particle/Analytic.hs` 的 `parallelThreshold` 未動；foreign-library 的 `build-depends` 仍只有 base／magic-boundary／bytestring／vector；沒有加 `-with-rtsopts`；`pm_stats`／`PmStats` 未觸碰（屬 F011）。

