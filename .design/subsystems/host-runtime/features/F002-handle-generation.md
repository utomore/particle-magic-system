---
id: F002
type: feature
title: handle-generation
description: 控制代碼改為世代標籤註冊表，釋放後再用回錯誤
status: done
created: 2026-08-20
updated: 2026-08-20
depends-on: []
related-adr: [ADR-022]
related-feature: []
---

# F002: 控制代碼的世代標籤

## 功能概述

**要解決的問題**：`src/ffi/Magic/FFI.hs` 的控制代碼是裸 `StablePtr`——`pm_cast_ex` 以 `newStablePtr . SpellCell =<< newIORef spell`（:425）配置，`pm_free` 以 `freeStablePtr`（:669）釋放，取用時 `withCell`（:302）直接 `deRefStablePtr`。這條路徑對 NULL 有防護，對**已釋放**與**偽造**的控制代碼完全沒有：`deRefStablePtr` 打到一個已被釋放的 stable pointer table 條目是未定義行為，重複 `freeStablePtr` 同樣是未定義行為，兩者都可能直接殺掉宿主進程。模組自己的註解把這件事寫得很清楚（:295「Any /other/ invalid handle (freed, forged) is undefined behaviour, as in any C API」），標頭也照抄了同一句（:288-289）。

而 [system.md](../../../system.md) 的產品等級驗收標準 **P-1** 是「庫在任何情況下不終止宿主進程」，use-after-free 又是宿主最常犯的錯。[ADR-022](../../../adr/ADR-022-host-runtime-contract.md) D3 因此修訂 [adr-0011](../../../../docs/adr/adr-0011-ffi-c-abi-boundary.md) D4 的那一句：控制代碼改為**帶世代標籤的不透明控制代碼**，已釋放、重複釋放或偽造的控制代碼被辨識出來並回 `PM_ERR_ARGS`，而不是未定義行為。

本功能把 M3 的**註冊表半邊**做出來：控制代碼的值本身編碼「種類 ＋ slot 索引 ＋ 世代」，庫內兩張註冊表把索引解析為 cell，世代不符即拒絕。宿主永遠不解參考它，標頭的 `PmSpell*`／`PmScene*` 不透明型別一個位元都不動。

**驗收標準**（契約卡原文）：

1. 釋放後再用、重複釋放、偽造指標三種情況皆回 `PM_ERR_ARGS` 且進程存活；
2. 合法控制代碼的所有操作輸出**逐位元不變**；
3. 標頭的不透明指標型別不變；
4. 單執行緒路徑的每次呼叫額外成本為**一次查表與比較**。

第 1 條在五個 `void` 符號、`pm_age`（`double`）與 `pm_occupancy_mask`（`uint32_t`）上無法字面成立——它們沒有錯誤碼通道。逐符號的裁定見「4. 解析與逐符號回傳表」與「待確認假設 A3」。

**明確不做**（契約卡）：不改變任何符號簽名；不做同控制代碼的併發保證（屬 F004 thread-model）；不回收識別碼。

補充的不做（本文件裁定）：**不改變 NULL 控制代碼的既有行為**。標頭已逐符號明文承諾 NULL 的回傳（「0 for a NULL handle」「Freeing NULL is a no-op」），那是凍結的文件承諾，既有測試也釘住了它；本功能只把「非 NULL 的無效控制代碼」從未定義行為改成錯誤碼。

## 相依性

`depends-on: []`——**可與階段一的其他 feature 平行開發**。

介面表反推的候選集合是空的：每一列的「來源文檔」都是 `-`，用到的介面全在既有程式碼（`Magic.FFI` 自己的 `withCell`／`withScene`／`pm_free`／`pm_cast_ex`／`pmErrArgs`／`writeErr`、`base` 的 `Foreign.StablePtr`／`Foreign.Ptr`／`Data.Bits`／`Data.IORef`／`System.IO.Unsafe`／`System.Mem`、`vector` 的 `Data.Vector.Mutable`）或既有測試（`FFIHarness`、`FFIContractSpec` 的標頭剖析器）裡，沒有一列指向進行中的任務文檔。

與平行 feature 的關係（合併面詳見「7. 與平行 feature 的合併關係」）：

| 平行項目 | 關係 |
|---|---|
| F001 exception-firewall | 同樣動 M3，但**巢狀位置不同**：防火牆在每個符號的最外層，控制代碼解析在 `withCell`／`withScene` 內。單向影響一處：F001 的 T6 用 `newStablePtr . SpellCell` 造毒化控制代碼，本功能合併後那個值會被判為偽造，需改用本功能匯出的 `newSpellHandle`（見 A7） |
| F003 rts-config-init | 動 `cbits/pm_init.c` 與 M1，與本功能零檔案交集。註冊表的內容在 `pm_shutdown` 之後隨 RTS 一起消失，狀態檢查（I3）由 F003 負責，本功能不重複 |
| F004 thread-model | **建立在本功能之上**（`design.md` 功能規劃 #4 依賴 #2）。本功能把註冊表設計成「同一 cell 的 read-modify-write 可原子化」，但不承諾任何併發保證，見「6. 給 F004 留的接縫」 |
| F005 step-planner-c-abi | 新增的符號不吃控制代碼（`pm_plan_steps` 是純函數），與本功能零交集 |

## 對應的 Level 2 契約

逐條對照 [design.md](../design.md)，確認未超出範圍：

| Level 2 條目 | 本功能做的事 | 是否超出 |
|---|---|---|
| **C2.3 控制代碼安全** | 全部實作：已釋放、重複釋放或偽造的控制代碼回 `PM_ERR_ARGS`（或該符號能表達的中性值），不是未定義行為；表徵為帶世代標籤的不透明控制代碼 | 否 |
| **I2（M2 → M3）的註冊表半邊** | 建立「控制代碼一律經註冊表解析，不直接解參考」這半條，並以測試守護 22 個吃控制代碼的符號全部經 `withCell`／`withScene` | 否。I2 的防火牆半邊屬 F001 |
| **資料流管線「驗證段」** | 「M3 控制代碼解析：世代標籤不符 → `PM_ERR_ARGS`」整段 | 否 |
| **C1.1 生命週期** | 「控制代碼為不透明指標」不變；`pm_cast` 配置、`pm_free` 釋放的生命週期不變（ADR-022 D3 明文保留） | 否。零符號變更、零結構變更 |
| **C1 只加不改** | 標頭不新增任何符號、常數或結構；只修訂已過期的散文（「freeing twice is undefined behaviour」）。`PM_ABI_VERSION` 維持 1、`.def` 不動 | 否 |
| **C2.2 執行緒模型** | **不實作**。本功能只確保註冊表的形狀不擋住 F004 | 否（明確不做） |
| **對外承諾「永不崩潰宿主」** | 補上 use-after-free 這一大類；例外類由 F001 補 | 否 |

## 實作方式

### 1. 控制代碼的表徵

沿用委派決策 D1：把「索引 ＋ 世代」編碼進不透明指標的**值**裡。理由是 D1 已經說的那一句——指向堆積標頭的真指標在釋放後讀取本身就是 UB，偵測不可靠——再加上兩個本文件查證後補上的理由：

- 現行程式碼**已經**在合成非 stable-pointer-table 的 `StablePtr` 了：`nullSpell = castPtrToStablePtr nullPtr`（:297），並且只用 `castStablePtrToPtr` 比較它（:300）。合成值只要不進 `deRefStablePtr`／`freeStablePtr` 就安全，這是同一個手法的推廣，不是新引入的風險。
- 編碼後的字**恆為奇數**（見下），因此永遠不是一個對齊的堆積位址：宿主若真的解參考它，會立刻在自己的行程裡吃到對齊或分頁錯誤（大聲失敗），而不是靜靜讀到別的東西。

版面（以 `WordPtr` 的位元寬 `w = finiteBitSize` 為準，下半字 = 低 `w/2` 位）：

| 位元 | 欄位 | 說明 |
|---|---|---|
| 0 | 合成位，恆為 **1** | 保證控制代碼的字永不為 0（不會與 NULL 混淆）、永不對齊 |
| 1 | 種類位 | 0 = 法術（`PmSpell*`）、1 = 場景（`PmScene*`） |
| 2 .. w/2−1 | slot 索引 | 64 位元平台 30 位元（約 10.7 億個同時存活的控制代碼） |
| w/2 .. w−1 | 世代 | 64 位元平台 32 位元；自 1 起算，每次釋放 +1 |

出貨平台（[design.md](../design.md) C4：Windows x86_64、Linux x86_64、macOS x86_64／arm64）全部是 64 位元，所以實際版面就是 1／1／30／32。以半字定義而非寫死 30／32，是為了讓 32 位元建置（14／16）也能編譯而不是靜默截斷；32 位元不在出貨矩陣內，不驗證。

### 2. 註冊表

法術與場景各一張，型別不同（`IORef ActiveSpell` 與 `IORef Scene`），所以是同一份參數化實作的兩個實例。每張表：

```text
slots : 可成長的可變陣列，元素為 Slot
        Slot = Empty !世代            -- 空著（未用過／已釋放）；世代是「下一次配置要發的號碼」
             | Live  !世代 !cell      -- 存活；世代是這個控制代碼的號碼
count : 已配置的 slot 數（陣列前綴）
free  : 自由 slot 的索引串列
```

整張表放在一個**頂層 `IORef`**（`unsafePerformIO` ＋ `NOINLINE`，外殼層的標準手法），這也讓它成為 GC 根：cell 的存活期由註冊表決定，與原本「`StablePtr` 是 GC 根」的語意等價，釋放後同樣立刻可回收。

**容器選擇不是自由的**：`test/FFIContractSpec.hs:237-242` 斷言 foreign-library 的 `build-depends` 只能是 `base`、`magic-boundary`、`bytestring`、`vector`。`containers` 的 `IntMap` 會讓那條測試變紅，而且 O(log n) 也不符合「一次查表」。`Data.Vector.Mutable` 的可變裝箱向量已在白名單內，`read` 是 O(1)，成長用 `grow` 倍增。

**世代溢位**：世代欄位加一會回到 0 時，該 slot **永久退休**（不進 `free` 串列）。64 位元平台上這需要同一個 slot 被釋放 2³² 次；退休的代價是一個 slot 的記憶體，遠好過讓控制代碼的值重複。

### 3. 生命週期：配置與釋放

只有兩個函數會改動註冊表，全部的併發討論都收斂在這兩處（見「6. 給 F004 留的接縫」）：

- **配置**：取一個自由 slot（沒有就成長陣列並取新的），把 `Empty g` 換成 `Live g cell`，回傳以 `(種類, 索引, g)` 編碼的控制代碼。`pm_cast_ex`（:425）與 `pm_scene_new`（:691）改為呼叫它，不再 `newStablePtr`。
- **釋放**：解析控制代碼；解析失敗（NULL、偽造、已釋放）一律**安全無操作**；成功則把 `Live g cell` 換成 `Empty (g+1)`（或退休），並把索引放回 `free`。`pm_free`（:666）與 `pm_scene_free`（:697）改為呼叫它，不再 `freeStablePtr`。

「重複釋放安全」由此直接成立：第二次釋放時 slot 已是 `Empty (g+1)`，世代比對不過。

**識別碼不回收**：slot 索引會被重用，但控制代碼的**值**永不重複——重用的 slot 一定帶著遞增後的世代。這與場景層「法術 id 永不重用」同精神（`pm_scene_dismiss` 的註解 :850-852 就是靠這一點才敢說「未知 id 是無操作」），而且把記憶體上限釘在「同時存活的控制代碼峰值」而非「歷史施法總次數」。這一條的解讀記在 A2。

### 4. 解析與逐符號回傳表

解析階梯（每一階都是一次比較，第 5、6 階共用同一次查表）：

| # | 檢查 | 不通過的判定 |
|---|---|---|
| 1 | 字 == 0 | **NULL**——走凍結行為，不是錯誤 |
| 2 | 合成位 == 1 | 偽造 |
| 3 | 種類位 == 期望的種類 | 偽造（含把 `PmScene*` 餵給 `pm_free` 這種錯用） |
| 4 | 索引 < `count` | 偽造 |
| 5 | slot 是 `Live` | 釋放後再用 |
| 6 | slot 世代 == 控制代碼世代 | 釋放後再用（slot 已被重用） |

1–4 是純字元運算（零配置），5–6 是**一次 `MV.read` 與一次相等比較**——驗收標準第 4 條的字面內容。

`withCell`（:302）與 `withScene`（:327）因此從「一個 fallback」變成「兩個 fallback」：NULL 一個、無效一個。22 個吃控制代碼的符號逐一補上第二個 fallback，**簽名一個都不動**：

| 符號 | 回傳型別 | NULL（凍結，不變） | 無效（釋放後／偽造／種類不符） |
|---|---|---|---|
| `pm_advance` | `void` | 無操作 | 無操作 |
| `pm_is_finished` | `int` | `1` | `PM_ERR_ARGS` |
| `pm_age` | `double` | `0` | `0`（無錯誤通道，見 A3） |
| `pm_observe` | `int` | `0` | `PM_ERR_ARGS` |
| `pm_observe_ex` | `int` | `0` | `PM_ERR_ARGS` |
| `pm_free` | `void` | 無操作 | 無操作 |
| `pm_spell_bounds` | `int` | `PM_ERR_ARGS` | `PM_ERR_ARGS` |
| `pm_spell_box` | `int` | `PM_ERR_ARGS` | `PM_ERR_ARGS` |
| `pm_emitter_count` | `int` | `0` | `PM_ERR_ARGS` |
| `pm_emitter_box` | `int` | `PM_ERR_ARGS` | `PM_ERR_ARGS` |
| `pm_occupancy` | `int` | `PM_ERR_ARGS` | `PM_ERR_ARGS` |
| `pm_occupancy_mask` | `uint32_t` | `0` | `0`（無錯誤通道，見 A3） |
| `pm_scene_free` | `void` | 無操作 | 無操作 |
| `pm_scene_cast` | `int` | `PM_ERR_ARGS` ＋ 訊息 | `PM_ERR_ARGS` ＋ 訊息 |
| `pm_scene_cast_many` | `int` | `PM_ERR_ARGS` ＋ 訊息 | `PM_ERR_ARGS` ＋ 訊息 |
| `pm_scene_dismiss` | `void` | 無操作 | 無操作 |
| `pm_scene_advance` | `void` | 無操作 | 無操作 |
| `pm_scene_observe` | `int` | `0` | `PM_ERR_ARGS` |
| `pm_scene_budget` | `int` | `PM_ERR_ARGS` | `PM_ERR_ARGS` |
| `pm_scene_count` | `int` | `0` | `PM_ERR_ARGS` |
| `pm_scene_spells` | `int` | `0` | `PM_ERR_ARGS` |
| `pm_scene_spell_bounds` | `int` | `PM_ERR_ARGS` | `PM_ERR_ARGS` |

三個檢查順序上的細節，照既有程式碼保留，不因本功能改變：

- `pm_occupancy` 的 `dim <= 0`（:1070）在控制代碼解析**之前**，兩條路都是 `PM_ERR_ARGS`，無歧義。
- `pm_spell_bounds`（:982）與 `pm_scene_spell_bounds`（:1105）的 NULL 輸出指標檢查在解析之前，同樣兩條路都是 `PM_ERR_ARGS`。
- `pm_scene_cast_many` 的 `count < 0`（:779）在 `withCast` 之前；`withCast`（:818）先判場景、再判 `out_id`。無效控制代碼在 `poke outId (-1)`（:822）**之前**就被擋下，所以 `out_id` 一個位元都不寫——與既有 NULL 場景的行為一致（`test/FFISceneSpec.hs:213` 的 `idSentinel` 斷言）。

無效控制代碼在兩個場景施法符號寫進 `err_buf` 的訊息文字沿用既有風格（例如 `"scene cast error: invalid scene handle"`）；訊息內容不進契約。

### 5. Haskell 面的型別維持 `StablePtr`

29 個 `foreign export ccall` 的 Haskell 型別維持 `StablePtr SpellCell` ／ `StablePtr SceneCell`，**一行宣告都不改**。控制代碼不再指向 stable pointer table 的條目，但這個型別在本模組裡已經只被當成「一個不透明的指標大小的值」使用（合成靠 `castPtrToStablePtr`、比較靠 `castStablePtrToPtr`），而 `deRefStablePtr`／`newStablePtr`／`freeStablePtr` 在本功能之後會從法術與場景路徑上**完全消失**。

換成 `Ptr SpellCell` 在 C 面是同一件事（兩者都以指標穿越），但會改動 29 個匯出宣告與 9 個測試模組的型別註記（`FFIHarness`、`FFILifecycleSpec`、`FFISceneSpec`、`FFISceneCastSpec`、`FFISpaceSpec`、`FFIObserveExSpec`、`FFIErrorSpec`、`Acceptance18Spec`、`ExampleHostSpec`），而這五份檔案正是 F001 同時在改的。取捨與理由記在 A1。

C# 綁定（`bindings/csharp/ParticleMagic.cs`）**零改動**：它已經全部以 `IntPtr` 承接控制代碼，從不解參考。C 範例的 `if (!s)` 判空也照常成立，因為合法控制代碼的字恆為奇數、永不為 0。

### 6. 給 F004 留的接縫

本功能**不承諾任何併發保證**，但不得把門堵死。三個結構性決定：

1. **法術狀態不住在註冊表裡**。slot 存的是既有的 `SpellCell (IORef ActiveSpell)`，`pm_advance` 的推進仍然是對那個 `IORef` 的 read-modify-write。F004 要的「同一控制代碼不丟更新」因此只需把 `readIORef`／`writeIORef`（:437-439）換成 `atomicModifyIORef'`，**完全不必動註冊表**。
2. **註冊表的解析路徑是唯讀的**：讀一次頂層 `IORef`、讀一個 slot。不寫。
3. **註冊表的變動只有兩個函數**（配置與釋放）。F004 若要讓 `pm_cast`／`pm_free` 也併發安全，只需替換這兩個函數內部的同步原語（例如頂層 `IORef` 改 `MVar`），22 個呼叫端一行都不動。

### 7. 與平行 feature 的合併關係

- **F001 exception-firewall**：套用位置是「等號右側最外層插一個組合子呼叫」，本功能改的是 `withCell`／`withScene` 的內部與各符號傳給它們的 fallback 引數。同一行只有縮排會撞。**唯一的實質互動**：F001 的 T6 以 `newStablePtr . SpellCell =<< newIORef (error "poisoned spell")` 造毒化控制代碼，本功能合併後這個值不在註冊表裡、會被判為偽造，於是回 `PM_ERR_ARGS` 而不是 `PM_ERR_INTERNAL`。解法是本功能匯出的 `newSpellHandle :: ActiveSpell -> IO (StablePtr SpellCell)`——它的參數是惰性的，`newSpellHandle (error "poisoned spell")` 與 F001 原本的寫法等價，且拿到的是**合法**控制代碼，會真的走進防火牆。建議編排者讓本功能先合併，或直接請 F001 的實作用這個函式（見 A7）。
- **F003 rts-config-init**：檔案零交集（`cbits/pm_init.c` vs `src/ffi/Magic/FFI.hs`）。
- **F004 thread-model**：見上一節；本功能是它的前置。
- **F005 step-planner-c-abi**：新符號不吃控制代碼；若 F005 先合併，本功能的逐符號表不需要增列。

### 8. 標頭與文件

標頭**不加任何符號、常數或結構**，只修訂三處已被本功能作廢的散文：

- `pm_free` 的 `/* Release a handle. Freeing NULL is a no-op; freeing twice is undefined behaviour, as in any C API. */`（:288-289）；
- `pm_scene_free` 的同一句（:311-312）；
- 檔頭 threading 段落引用 ADR-0011 D4 的「one handle is owned by one thread」（:72-73）**保留不動**——那是 F004 的地盤，本功能只改「無效控制代碼是 UB」這件事。

改寫後的內容加一段散文，說明「已釋放、重複釋放與偽造的控制代碼一律被辨識並回 `PM_ERR_ARGS`（沒有錯誤碼通道的符號回中性值：`pm_age` → 0、`pm_occupancy_mask` → 0、`void` 符號無操作），庫不會因此終止宿主進程」，並以一個哨兵詞讓守門測試釘住（手法同既有的 `right-handed`／`0xRRGGBBAA`）。

`docs/integration.md` 的對應敘述同步；`PM_ABI_VERSION` 不動、`.def` 不動、`headerFunctions` 解出的宣告集合仍是 31 條。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `withCell :: StablePtr SpellCell -> b -> (IORef ActiveSpell -> IO b) -> IO b` | `src/ffi/Magic/FFI.hs:302` | - | 改寫為三路解析（NULL／無效／有效）；12 個吃法術控制代碼的符號全部經它 |
| `withScene :: StablePtr SceneCell -> b -> (IORef Scene -> IO b) -> IO b` | `src/ffi/Magic/FFI.hs:327` | - | 同上，10 個場景符號 |
| `newtype SpellCell = SpellCell (IORef ActiveSpell)` | `src/ffi/Magic/FFI.hs:290` | - | 註冊表 slot 存放的內容物；型別與構造子皆不變 |
| `newtype SceneCell = SceneCell (IORef Scene)` | `src/ffi/Magic/FFI.hs:317` | - | 同上（場景側） |
| `nullSpell :: StablePtr SpellCell`、`isNullSpell :: StablePtr SpellCell -> Bool` | `src/ffi/Magic/FFI.hs:296, 299` | - | NULL 判定成為解析階梯第一階；兩者的定義與語意不變 |
| `nullScene :: StablePtr SceneCell`、`isNullScene :: StablePtr SceneCell -> Bool` | `src/ffi/Magic/FFI.hs:321, 324` | - | 同上 |
| `pm_cast_ex :: CString -> Ptr CFloat -> Ptr CFloat -> Word64 -> CString -> CInt -> Ptr (StablePtr SpellCell) -> IO CInt` | `src/ffi/Magic/FFI.hs:410`（配置點 :425） | - | 唯一的法術控制代碼配置點，改為經註冊表 |
| `pm_scene_new :: CInt -> IO (StablePtr SceneCell)` | `src/ffi/Magic/FFI.hs:689`（配置點 :691） | - | 唯一的場景控制代碼配置點，改為經註冊表 |
| `pm_free :: StablePtr SpellCell -> IO ()` | `src/ffi/Magic/FFI.hs:666` | - | 改為經註冊表釋放；不再 `freeStablePtr` |
| `pm_scene_free :: StablePtr SceneCell -> IO ()` | `src/ffi/Magic/FFI.hs:697` | - | 同上 |
| `withCast :: StablePtr SceneCell -> Ptr CFloat -> Ptr CFloat -> Word64 -> CString -> CInt -> Ptr CInt -> (IORef Scene -> CastContext -> IO CInt) -> IO CInt` | `src/ffi/Magic/FFI.hs:808` | - | 兩個場景施法符號的共用檢查；無效控制代碼要在 `poke outId (-1)`（:822）之前擋下 |
| `pmOk, pmErrJson, pmErrBudget, pmErrCapacity, pmErrArgs, pmErrQuota :: CInt`（`pmErrArgs = -4`） | `src/ffi/Magic/FFI.hs:205-221` | - | 無效控制代碼的回傳碼；不新增任何常數 |
| `writeErr :: CString -> CInt -> String -> IO ()` | `src/ffi/Magic/FFI.hs:1320` | - | 兩個場景施法符號拒絕無效控制代碼時寫訊息（截斷安全，`NULL`／`len <= 0` 無操作） |
| `castFail :: CString -> CInt -> CInt -> String -> IO CInt` | `src/ffi/Magic/FFI.hs:845` | - | 同上，沿用既有的「寫訊息＋回碼」形狀 |
| `castStablePtrToPtr :: StablePtr a -> Ptr ()` | `base`（GHC 9.14.1，`Foreign.StablePtr`；以 `ghci :t` 實查） | - | 取出控制代碼的字 |
| `castPtrToStablePtr :: Ptr () -> StablePtr a` | `base`，`Foreign.StablePtr` | - | 合成控制代碼；既有 `nullSpell`（:297）已是同一手法 |
| `ptrToWordPtr :: Ptr a -> WordPtr`、`wordPtrToPtr :: WordPtr -> Ptr a` | `base`，`Foreign.Ptr` | - | 字與指標互轉 |
| `newtype WordPtr = WordPtr Word`，具 `Bits`／`FiniteBits`／`Integral` instance | `base`，`Foreign.Ptr`（`ghci :i WordPtr` 實查） | - | 位元欄位的打包與拆解 |
| `shiftL, shiftR :: Bits a => a -> Int -> a`、`(.&.), (.|.) :: Bits a => a -> a -> a`、`finiteBitSize :: FiniteBits b => b -> Int` | `base`，`Data.Bits` | - | 版面運算；`finiteBitSize` 決定半字寬 |
| `newIORef :: a -> IO (IORef a)`、`readIORef :: IORef a -> IO a`、`writeIORef :: IORef a -> a -> IO ()`、`atomicModifyIORef' :: IORef a -> (a -> (a, b)) -> IO b` | `base`，`Data.IORef` | - | cell 與註冊表狀態；`atomicModifyIORef'` 讓配置／釋放寫成單一 RMW 形狀 |
| `unsafePerformIO :: IO a -> a` | `base`，`System.IO.Unsafe` | - | 兩張頂層註冊表（搭配 `NOINLINE`） |
| `Data.Vector.Mutable.new :: PrimMonad m => Int -> m (MVector (PrimState m) a)`、`read :: PrimMonad m => MVector (PrimState m) a -> Int -> m a`、`write :: PrimMonad m => MVector (PrimState m) a -> Int -> a -> m ()`、`grow :: PrimMonad m => MVector (PrimState m) a -> Int -> m (MVector (PrimState m) a)`、`length :: MVector s a -> Int`、`type IOVector = MVector RealWorld` | `vector-0.13.2.0`，`Data.Vector.Mutable`（`ghci :t` 實查） | - | slot 陣列；`vector` 已在外殼層依賴白名單內，不必改 cabal 的 `build-depends` |
| `getAllocationCounter :: IO Int64` | `base`，`System.Mem` | - | 「一次查表與比較」的成本斷言（解析路徑的每次呼叫配置量不隨存活控制代碼數成長） |
| foreign-library 的 `build-depends` 白名單 `base`／`magic-boundary`／`bytestring`／`vector` | `particle-magic.cabal:242-245`，由 `test/FFIContractSpec.hs:237-242` 斷言 | - | 註冊表不得引入 `containers`；這是選 `vector` 而非 `IntMap` 的硬性理由 |
| `typedef struct PmSpell PmSpell;`、`typedef struct PmScene PmScene;` | `include/particle_magic.h:161, 303` | - | 不透明型別不變（驗收標準第 3 條） |
| `pm_free` ／ `pm_scene_free` 的「freeing twice is undefined behaviour」散文 | `include/particle_magic.h:288-289, 311-312` | - | 本功能要修訂的過期敘述 |
| `headerFunctions :: IO [String]`、`headerDefines :: IO [(String, Int)]`、`readUtf8 :: FilePath -> IO String` | `test/FFIContractSpec.hs:283, 314, 351`（已匯出給 `BindingContractSpec` 用） | - | 標頭守門沿用既有剖析器，不做第二份 |
| `castOk :: BS.ByteString -> CastContext -> IO (StablePtr SpellCell)`、`observeRaw :: StablePtr SpellCell -> Int -> Int -> IO Observed`、`data Observed { obCode, obPosX, …, obInfo }`、`spellBytes :: FilePath -> IO BS.ByteString`、`referenceStates :: BS.ByteString -> [Float] -> [ActiveSpell]` | `test/FFIHarness.hs:111, 155, 128-136, 80, 218` | - | 逐位元不變的回歸，以及新測試的施法與觀測 |
| NULL 控制代碼的既有斷言（`pm_scene_count nullScene == 0`、`sceneBudgetOf nullScene == pmErrArgs`、`pm_occupancy_mask nullSpell == 0`、`pm_is_finished nullSpell == 1` …） | `test/FFISceneSpec.hs:187-215`、`test/FFISpaceSpec.hs:151-211`、`test/FFILifecycleSpec.hs:92-100` | - | 凍結行為的回歸網；本功能不得讓其中任何一條變紅 |

## 新增的介面

### C 面（`include/particle_magic.h`）

**零新增**。無新符號、無新常數、無新結構、`PM_ABI_VERSION` 維持 1、`.def` 不動、不透明型別不變。唯一的改動是把兩處「freeing twice is undefined behaviour」的散文改寫為實況，並加一段控制代碼安全的說明（見「8. 標頭與文件」）。

### C# 面

**零新增**。`bindings/csharp/ParticleMagic.cs` 以 `IntPtr` 承接控制代碼且從不解參考，不受表徵變更影響。

### Haskell 面（`Magic.FFI`；非 C 契約的一部分，比照既有的 `SpellCell (..)`／`writeErr` 從「Internals」區匯出給測試）

| 簽名 | 說明 |
|---|---|
| `newSpellHandle :: ActiveSpell -> IO (StablePtr SpellCell)` | 註冊一個法術並取得控制代碼。參數惰性，`newSpellHandle (error "…")` 即 F001 要的毒化控制代碼（見 A7） |
| `newSceneHandle :: Scene -> IO (StablePtr SceneCell)` | 場景側的同一件事 |
| `freeSpellHandle :: StablePtr SpellCell -> IO ()` | `pm_free` 的本體；無效控制代碼為安全無操作 |
| `freeSceneHandle :: StablePtr SceneCell -> IO ()` | `pm_scene_free` 的本體 |
| `spellRegistryStats :: IO (Int, Int)` | `(存活控制代碼數, 已配置 slot 數)`；測試用來證明 slot 被重用、表不隨施法次數成長 |
| `sceneRegistryStats :: IO (Int, Int)` | 場景側的同一件事 |

這六個名字被 T2／T3／T8 的測試直接呼叫，因此**鎖定**（理由同 F001 的 A6：實作自主權在這裡讓渡給可測性）。註冊表本身的資料型別、欄位命名、成長策略與自由串列的表示法不鎖定。

## TodoList

- [x] T1: 控制代碼的編碼／解碼純函數：合成位、種類位、slot 索引、世代四欄的打包與拆解，以半字寬定義版面  `dep: -`
- [x] T2: 參數化的註冊表與四個生命週期操作（`newSpellHandle`／`freeSpellHandle`／`newSceneHandle`／`freeSceneHandle`），含自由串列、世代遞增、溢位退休；以 `Data.Vector.Mutable` 實作，`build-depends` 不動  `dep: T1`
- [x] T3: `pm_cast_ex`（:425）與 `pm_scene_new`（:691）改為經註冊表配置；`pm_free`（:666）與 `pm_scene_free`（:697）改為經註冊表釋放，不再出現 `newStablePtr`／`freeStablePtr`／`deRefStablePtr`  `dep: T2`
- [x] T4: `withCell`／`withScene` 改寫為三路解析（NULL／無效／有效），22 個吃控制代碼的符號依「逐符號回傳表」補上第二個 fallback；不動任何簽名，既有的檢查順序不變  `dep: T3`
- [x] T5: 標頭與 `docs/integration.md` 的敘述修訂：兩處「freeing twice is undefined behaviour」改寫，新增控制代碼安全散文段落（含中性值清單）；符號集合、`PM_ABI_VERSION`、`.def` 皆不動  `dep: T4`
- [x] T6: 六個 Internals 介面加入 `Magic.FFI` 的匯出區；新測試模組登記進 `particle-magic.cabal` 的 `test-suite spec` `other-modules`  `dep: T2`
- [x] T7: 合法控制代碼的輸出逐位元不變的回歸（九欄與 `batch_info` 對照 `Magic.Interface` 參考路徑）  `dep: T4`
- [x] T8: 成本與規模的斷言：解析路徑的每次呼叫配置量不隨存活控制代碼數成長；slot 在釋放後被重用，已配置 slot 數收斂到存活峰值  `dep: T4, T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `FFIHandleSpec` — `it "round-trips kind, slot and generation through the handle word"` | 屬性測試：任意 `(種類, 索引, 世代)` 編碼後解回原值；字恆為奇數（合成位）、恆非 0；`castStablePtrToPtr` 出來的值與 `nullPtr` 不等；種類位可分辨法術與場景 |
| T2 | `FFIHandleSpec` — `it "reuses slots with a fresh generation and never repeats a handle value"` | 配置 N 個、釋放其中 M 個、再配置 M 個：`spellRegistryStats` 的 slot 數不超過 N，且**全部發出過的控制代碼字兩兩相異**；釋放後的舊控制代碼解析失敗；重複釋放為無操作且統計不再變動 |
| T3 | `FFIHandleSpec` — `it "casts and frees through the registry, with no StablePtr left in the path"` | `pm_cast_ex` 回傳的控制代碼合法且 `spellRegistryStats` 存活數 +1，`pm_free` 後 −1，第二次 `pm_free` 不變；`pm_scene_new`／`pm_scene_free` 同；外加原始碼稽核：`src/ffi/Magic/FFI.hs` 不再出現 `newStablePtr`／`freeStablePtr`／`deRefStablePtr` |
| T4 | `FFIHandleSpec` — `it "answers the invalid-handle table for freed, double-freed and forged handles"` | 表驅動，22 個符號 × 三種無效來源（已釋放的控制代碼、種類不符的控制代碼、以任意字合成的偽造控制代碼）：回傳值與「逐符號回傳表」的無效欄逐格相符，且測試進程存活到最後一條；`pm_scene_cast*` 額外斷言 `out_id` 未被寫入（`idSentinel` 手法） |
| T5 | `FFIContractSpec` — `it "documents handle safety instead of undefined behaviour"` | 標頭不再含 `"undefined behaviour"` 於 `pm_free`／`pm_scene_free` 的敘述；含控制代碼安全段落的哨兵詞；`headerFunctions` 的集合仍是既有 31 條、`PM_ABI_VERSION` 仍為 1、`headerDefines` 未新增任何常數 |
| T6 | `FFIHandleSpec` — `it "exposes the registry internals the specs drive"` | 六個 Internals 介面可從 `Magic.FFI` 匯入並可呼叫（編譯即斷言的一半）；`newSpellHandle (error "poisoned")` 回傳合法控制代碼且解析得到 cell（F001 的毒化路徑接口，見 A7） |
| T7 | `FFIHandleSpec` — `it "leaves a legal handle's output bit-identical"` | 以 `FFIHarness.castOk` ＋ `observeRaw` 取一個出貨範例陣的九欄與 `batch_info`，與 `Magic.Interface` 參考路徑逐位元比對（`Float` 以位元樣式比）；既有 `FFILifecycleSpec`／`FFIObserveSpec`／`FFISceneSpec`／`FFISpaceSpec`／`Acceptance9Spec`／`Acceptance18Spec`／`Acceptance25Spec` 保持綠是同一條的旁證 |
| T8 | `FFIHandleSpec` — `it "resolves in constant cost regardless of how many handles are live"` | 以 `getAllocationCounter` 量 `pm_age` 連續呼叫的每次配置量，在「存活 1 個控制代碼」與「存活 4096 個控制代碼」兩種規模下相同（差值為 0），且絕對值小於一個小常數；同時斷言 4096 個全部釋放後再配置 4096 個，已配置 slot 數不成長 |

## 待確認假設

- **A1**: Haskell 面的控制代碼型別是否要從 `StablePtr SpellCell`／`StablePtr SceneCell` 換成更誠實的 `Ptr` 新型別 → 採取：**維持 `StablePtr`**，因為（a）C 面完全等價，兩者都以指標穿越，驗收標準第 3 條講的是標頭的不透明型別；（b）既有 `nullSpell = castPtrToStablePtr nullPtr` 已是同一手法的先例，新路徑不再呼叫 `deRefStablePtr`／`freeStablePtr`，合成值不會進入 stable pointer table；（c）換型別要改 29 個匯出宣告與 9 個測試模組的型別註記，其中 5 個檔案 F001 正在同時改 → 影響：若編排者裁定要換，T3／T4 的工作量與合併風險上升一級，但設計本身（編碼、註冊表、解析階梯、逐符號表）一行都不用改。
- **A2**: 「不回收識別碼」的解讀 → 採取：**slot 索引可回收，控制代碼的值永不重複**（重用的 slot 必帶遞增後的世代），這也是 ADR-022 D3「世代標籤」存在的唯一理由，並與場景層「法術 id 永不重用」同精神 → 影響：若裁定連 slot 都不得回收，註冊表退化為只增不減的墓碑表、世代欄位變成常數，記憶體隨**歷史施法總次數**線性成長（每秒 60 次施法的宿主一小時累積約 21 萬個墓碑）。
- **A3**: 契約卡「三種情況皆回 `PM_ERR_ARGS`」對七個沒有錯誤碼通道的符號無法字面成立（`pm_advance`、`pm_free`、`pm_scene_free`、`pm_scene_dismiss`、`pm_scene_advance` 回 `void`；`pm_age` 回 `double`；`pm_occupancy_mask` 回 `uint32_t`） → 採取：能表達錯誤碼的 15 個一律 `PM_ERR_ARGS`，其餘為安全無操作或中性值（`pm_age` → 0、`pm_occupancy_mask` → 0，與既有 NULL 行為一致且在重疊測試上是 fail-safe），並逐符號寫進標頭 → 影響：若要求全部可回報，得新增 `pm_free_ex` 之類的回碼版本符號（加法，`PM_ABI_VERSION` 仍可不動），那是新的 C 契約，需編排者裁決並回寫 `design.md` C2.3；建議 C2.3 補一句「沒有錯誤碼通道的符號回中性值」。
- **A4**: NULL 控制代碼與「無效」控制代碼是否要區分 → 採取：**區分**。NULL 的回傳值是標頭逐符號明文承諾、且被既有測試釘住的凍結行為（`test/FFISceneSpec.hs:187-215` 等），本功能不動它；非 NULL 的無效控制代碼原本是 UB，改回 `PM_ERR_ARGS`。這也讓宿主能區分「`pm_cast` 失敗後忘了檢查」與「用了已釋放的控制代碼」兩種 bug → 影響：若裁定「無效 ≡ NULL」，逐符號表的無效欄整欄改成 NULL 欄的值，use-after-free 會靜默回中性值而非錯誤，驗收標準第 1 條就只剩「進程存活」半條。
- **A5**: 世代溢位的處理 → 採取：世代加一會回到 0 時**永久退休該 slot** → 影響：若改為讓世代繞回，同一個控制代碼的值理論上會重複（需 2³² 次釋放）；若改為在溢位時回報錯誤，`pm_free` 沒有回碼通道可用。
- **A6**: 偽造控制代碼的偵測上限 → 採取：偶數字、種類不符、索引越界、slot 已空、世代不符全部攔下；一個**恰好等於某個現存合法控制代碼**的偽造字無法辨識，文件明說「這是任何表徵方案的共同上限，不是本方案的缺陷」 → 影響：若要更強的保證（例如加入一個進程內隨機的 salt 混入世代欄），世代可用位元減少、且測試無法再構造可預測的合法字，T1／T4 的測試手法要跟著改。
- **A7**: F001 的「刻意觸發內部失敗」路徑會被本功能作廢——它以 `newStablePtr . SpellCell =<< newIORef (error "poisoned spell")` 造控制代碼，本功能合併後那個字不在註冊表裡，會回 `PM_ERR_ARGS` 而非 `PM_ERR_INTERNAL` → 採取：本功能匯出 `newSpellHandle`／`newSceneHandle`（參數惰性，`newSpellHandle (error "…")` 與原寫法等價但回傳**合法**控制代碼），並在 T6 加一條測試釘住這個用法 → 影響：建議編排者讓本功能先合併、或直接請 F001 的實作採用這兩個函式；若 F001 先合併，其 T6 需改兩行（import 與構造）。這是兩份文檔之間唯一的實質互動，不構成 `depends-on`（本功能不需要 F001 的任何產出）。

- **A8**（實作時新增）: slot 空間耗盡時該回什麼——設計文檔沒寫，因為 64 位元平台上那是 2³⁰ 個同時存活的控制代碼(裝箱 cell 本身早就吃光位址空間) → 採取：`registryInsert` 回 NULL 字;`pm_cast_ex` 因此回 `PM_ERR_CAPACITY` 並寫訊息 `"spell handle table exhausted"`,`pm_scene_new` 回 `NULL`。理由是「別名一個現存的合法控制代碼」比「回報失敗」壞得多 → 影響：標頭 `pm_scene_new` 的散文寫著「Never returns NULL in this generation」,這條路徑理論上與它相牴觸(實務上不可達,無測試能構造)。若編排者要求嚴格相符,得改標頭那一句或改採「耗盡即 `error`」(但那會撞上 F001 的防火牆,回 `PM_ERR_INTERNAL`)。
- **A9**（實作時新增）: T8 的 1-to-1 測試寫「兩種規模下每次呼叫配置量差值為 **0**」→ 採取：改為「20 萬次呼叫的總配置量差 < 65536 位元組」(等於每次呼叫差 < 0.33 位元組),外加「每次呼叫配置量 < 128 位元組」。理由是 `getAllocationCounter` 以 nursery block 為同步顆粒度、不是逐次配置精確,字面的 0 會偶發性變紅 → 影響：斷言的語意不變(成本不隨存活控制代碼數成長),只是容忍計數器本身的量測誤差;若要字面的 0,得改用 `+RTS -s` 或 `GHC.Stats` 的全域統計,並讓測試獨佔進程。

## 實作備註

- **註冊表放在新模組 `src/ffi/Magic/FFI/Registry.hs`**，而不是塞進已有 1300 行的 `Magic.FFI`。理由是三個：與 F001 的合併面更小（F001 改 `Magic.FFI` 的每個符號，本功能的核心邏輯完全不在那個檔案裡）、`Magic.FFI.hs` 的原始碼稽核（T3）因此乾淨、F004 要加同步時只需要動一個檔。代價是 `particle-magic.cabal` 的 `foreign-library` 與 `test-suite spec` 兩處 `other-modules` 各加一行——`FFIContractSpec` 的 `has "other-modules" "Magic.FFI"` 斷言仍然命中原本那一行，沒有變紅。`build-depends` 一個字都沒動。
- 六個 Internals 介面（`newSpellHandle`／`freeSpellHandle`／`newSceneHandle`／`freeSceneHandle`／`spellRegistryStats`／`sceneRegistryStats`）如文檔所寫從 `Magic.FFI` 匯出；註冊表本身的泛型介面（`Registry`／`HandleKind`／`Resolved`／`encodeHandle`／`decodeHandle`／…）從 `Magic.FFI.Registry` 匯出給 T1／T4 的測試直接驅動。
- **A7 已兌現並被測試釘住**：`newSpellHandle` 的參數惰性，`newSpellHandle (error "poisoned spell")` 回傳合法控制代碼，`pm_age` 強制求值時真的會炸出 `ErrorCall`（T6 的測試就是這一條）；同一條也對 `newSceneHandle` ／ `pm_scene_count` 驗過。F001 可直接改用這兩個函式。
- **F004 的接縫維持原樣**：兩張表都是頂層 `IORef (Table a)`（未改成 `MVar`），解析路徑只有 `readIORef` ＋ 一次 `MV.read`、不寫入；所有變動集中在 `registryInsert`／`registryRelease` 兩個函數內。
- 標頭的修訂比文檔預期的稍多一點：除了兩處 `pm_free`／`pm_scene_free` 的散文與新增的「Handle safety」段落，`examples/c/main.c` 那句「Freeing twice would be undefined behaviour」也一併更正（它是同一句話的第三份拷貝，留著就是錯的）。T5 的守門測試直接斷言**整個標頭不再出現 `undefined behaviour`** 字串，並釘住 31 條宣告與 19 個 `#define` 名稱集合不變。
- `pm_scene_cast`／`pm_scene_cast_many` 的無效控制代碼訊息是 `"scene cast error: invalid scene handle"`；訊息內容不進契約，只是與既有 `"scene cast error: null scene"` 同風格。
