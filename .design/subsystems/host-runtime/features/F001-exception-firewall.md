---
id: F001
type: feature
title: exception-firewall
description: 每個 C 匯出符號包例外防火牆，庫永不殺宿主
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: []
related-adr: [ADR-022]
related-feature: []
---

# F001: 例外防火牆

## 功能概述

**要解決的問題**：`src/ffi/Magic/FFI.hs` 的 29 個 `foreign export ccall` 沒有任何一個 `catch`。一個 Haskell 例外穿出 C 邊界，RTS 會終止整個宿主進程，訊息印在沒人看的 stderr。純核心目前是全函數，但堆積耗盡、深度遞迴、未來的不完整模式、以及 `deRefStablePtr` 打到已釋放的控制代碼，都不是核心能以型別排除的事。這是 [system.md](../../../system.md) 產品等級驗收標準 **P-1** 的唯一出口。

本功能在**每一個匯出符號的本體外層**加一道防火牆：攔截一切 Haskell 例外，映射為新錯誤碼 `PM_ERR_INTERNAL`（−6），並在該符號帶訊息緩衝時寫入例外文字。同時把 `PM_ERR_STATE`（−7）兩個常數一起加進標頭與綁定（使用者是 F003、F004，本功能只負責常數本身與對帳）。

**驗收標準**（契約卡原文，逐條可機械檢查）：

1. 每一個匯出符號（含既有 31 個中的 29 個 Haskell 匯出）都經由防火牆；
2. 一條刻意觸發內部失敗的測試路徑回 `PM_ERR_INTERNAL`，並在有訊息緩衝時寫入例外文字，**進程存活**；
3. 合法輸入的輸出**逐位元不變**；
4. 標頭新增 `PM_ERR_INTERNAL`（−6）與 `PM_ERR_STATE`（−7），`PM_ABI_VERSION` 不動；
5. C# 綁定的常數對帳同步。

**明確不做**（契約卡）：不把防火牆當錯誤處理——核心「不失敗」與邊界「錯誤轉成值」的原則不變，防火牆是**最後一道**，攔到即缺陷；不新增任何語意；不處理控制代碼有效性（屬 F002 handle-generation）。

補充的不做（本文件裁定，屬上一條的展開）：**不在防火牆路徑承諾 all-or-nothing**。`pm_observe` 的「錯誤路徑一個位元組都不寫」是容量檢查的承諾；例外若發生在複製途中，宿主緩衝可能是半更新的。這是缺陷路徑，庫只承諾「不崩、有錯誤碼」。

## 相依性

`depends-on: []`——**可與其他所有階段一 feature 平行開發**。

介面表反推的候選集合是空的：本功能用到的每一個介面都在既有程式碼裡（`Magic.FFI` 自己的常數與 `writeErr`、`base` 的 `Control.Exception`、既有測試的標頭剖析器與 marshalling harness），沒有一列的「來源文檔」指向進行中的任務文檔。

與平行 feature 的關係是**單向的、被依賴**，不是依賴：

| 平行項目 | 關係 |
|---|---|
| F002 handle-generation | 同樣動 M3。F002 換掉控制代碼的表徵（`StablePtr` → 世代標籤），本功能只在符號本體外層加一層，兩者在同一個 `pm_*` 定義上是**不同的巢狀位置**（防火牆在最外，控制代碼解析在內），文字衝突僅限於同一行的縮排 |
| F003 rts-config-init、F004 thread-model | 消費本功能加進標頭的 `PM_ERR_STATE`；它們依賴本功能，本功能不依賴它們 |
| F005 step-planner-c-abi | 新增 `pm_plan_steps` 等符號。新符號**必須**自行包上防火牆——本功能的守門測試是從原始碼動態列舉 `foreign export ccall` 的，漏包就是紅燈（見「合併順序」） |

## 對應的 Level 2 契約

逐條對照 [design.md](../design.md)，確認未超出範圍：

| Level 2 條目 | 本功能做的事 | 是否超出 |
|---|---|---|
| **C2.1 例外防火牆** | 全部實作：每個匯出符號攔截一切 Haskell 例外並映射為 `PM_ERR_INTERNAL`（回傳指標者回 NULL、回傳計數者回 −6），庫在任何情況下不終止宿主進程 | 否 |
| **C1.9 錯誤碼** | 新增 `PM_ERR_INTERNAL`（−6）與 `PM_ERR_STATE`（−7）兩個常數；訊息沿用既有的 UTF-8 邊界安全截斷（`writeErr`） | 否。`PM_ERR_STATE` 的**語意**由 F003／F004 落地，本功能只加常數與對帳 |
| **I2（M2 → M3）的防火牆半邊** | 建立「每個匯出符號的本體都經由防火牆執行」這半條，並以原始碼機械對帳守護 | 否。I2 的另一半（控制代碼一律經註冊表解析）屬 F002 |
| **C1 只加不改** | 標頭只加兩個 `#define`，不動任何符號、結構或既有常數；`PM_ABI_VERSION` 維持 1 | 否 |
| **C3.1 雙向對帳** | C# 綁定同步兩個常數，既有的雙向對帳測試自動涵蓋 | 否 |
| 資料流管線「業務處理段」 | 防火牆包住該段的一切（M2 呼叫 boundary-host 條目 → Haskell 例外 → `PM_ERR_INTERNAL` ＋ 訊息） | 否 |

## 實作方式

### 1. 兩個組合子

在 `Magic.FFI` 內新增兩個組合子（模組內部實作，但比照 `writeErr` 從「Internals（not part of the C contract; exposed for testing）」匯出，讓測試能直接餵它會拋的動作）：

```haskell
-- 沒有訊息緩衝的符號用這個：攔到就回哨兵。
firewall :: a -> IO a -> IO a

-- 帶 err_buf 的符號用這個：攔到就寫入例外文字，再回哨兵。
firewallErr :: CString -> CInt -> a -> IO a -> IO a
```

`firewall sentinel = firewallErr nullPtr 0 sentinel`，所以只有一份實作。本體是：

1. `try (action >>= evaluate)`，型別註記為 `SomeException`；
2. `Right a` → 直接回 `a`；
3. `Left e` → 取訊息、`writeErr buf len msg`、回 `sentinel`。

**`evaluate` 不可省**，這是本功能最容易漏的一點。GHC 的 `foreign export` 是在包裝器回傳之後才把結果拆箱交給 C，而現有程式碼有好幾個符號把計算留在 thunk 裡：

- `pm_age` 的 `let Time t = spellAge spell in pure (CDouble t)`——`t` 是 thunk；
- `pm_is_finished` 的 `pure (if isFinished spell then 1 else 0)`——條件是 thunk。

沒有 `evaluate`，這些例外會在 `try` 的範圍**之外**才爆，防火牆等於不存在。把結果強制到 WHNF 就夠了：`CInt`／`CDouble`／`Word32` 的 WHNF 即完整值，`StablePtr` 與 `()` 亦然（外殼層的依賴白名單只有 base／magic-boundary／bytestring／vector，`deepseq` 不在其中，也不需要）。

**取訊息本身要再包一層**：`displayException e` 可能再拋（例外裡藏著會爆的 thunk）。作法是把 `"internal error: " ++ displayException e` 取前綴（長度上限取一個小常數，反正 `writeErr` 還要截斷）後 `evaluate` 到底，外面再套一次 `try`；失敗就退回一句固定文字。訊息文字內容不進契約，只保證是可讀的 UTF-8。

`writeErr` 已經處理 `NULL` 緩衝與 `len <= 0`，所以 `firewall` 傳 `nullPtr 0` 是安全的無操作，不需要第二條路徑。

### 2. 逐符號套用與哨兵表

29 個 `foreign export ccall` 依回傳型別分五類，每類一個哨兵：

| 回傳型別 | 符號 | 數量 | 哨兵 | 依據 |
|---|---|---|---|---|
| `IO CInt` | `pm_abi_version`、`pm_max_particles`、`pm_cast_ex`、`pm_is_finished`、`pm_observe`、`pm_observe_ex`、`pm_scene_cast`、`pm_scene_cast_many`、`pm_scene_observe`、`pm_scene_budget`、`pm_scene_count`、`pm_scene_spells`、`pm_spell_bounds`、`pm_spell_box`、`pm_emitter_count`、`pm_emitter_box`、`pm_occupancy`、`pm_scene_spell_bounds`、`pm_project`、`pm_depth_order` | 20 | `pmErrInternal`（−6） | ADR-022 D2「回傳計數者回 −6」 |
| `IO (StablePtr …)` | `pm_cast`、`pm_scene_new` | 2 | `nullSpell` ／ `nullScene` | ADR-022 D2「回傳指標者回 NULL」 |
| `IO ()` | `pm_advance`、`pm_free`、`pm_scene_free`、`pm_scene_dismiss`、`pm_scene_advance` | 5 | `()`（吞下） | 委派決策：void 符號吞下並不終止進程 |
| `IO CDouble` | `pm_age` | 1 | `-6.0` | 見「待確認假設 A1」 |
| `IO Word32` | `pm_occupancy_mask` | 1 | `0` | 見「待確認假設 A2」 |

`pm_is_finished` 回 −6 在 C 側是 truthy，宿主的 `while (!pm_is_finished(s))` 會結束迴圈而不是卡死——這是這個哨兵在本符號上恰好正確的原因，值得在標頭寫一句。

帶 `err_buf` 的四個符號（`pm_cast`、`pm_cast_ex`、`pm_scene_cast`、`pm_scene_cast_many`）用 `firewallErr`，其餘用 `firewall`。

**巢狀是允許且無害的**：`pm_cast` 的本體是呼叫已被包住的 `pm_cast_ex`，`pm_observe` 呼叫 `pm_observe_ex`。內層攔到時外層根本不會觸發，而 `pm_cast` 讀回的 `out` 仍是 `nullSpell`，行為正確。守門測試要求「每個匯出符號自己的定義塊都出現組合子」，所以這兩個也要各自包，不能靠委派。

套用形式是在既有定義的等號右側最外層插入一個組合子呼叫，**不動任何既有邏輯、不動任何簽名**。這是「合法輸入的輸出逐位元不變」的結構性理由：成功路徑上，防火牆只多做一次 `try` 與一次已是 WHNF 值的 `evaluate`。

### 3. 標頭

在 `include/particle_magic.h` 既有錯誤碼區塊之後加：

```c
/* The firewall caught a Haskell exception: something inside the library
   is broken (ADR-022 D2). Never the host's fault, always worth a bug
   report; the library stays usable and your process stays alive. */
#define PM_ERR_INTERNAL (-6)

/* The host called out of order: using the library before pm_init, or
   initialising again after pm_shutdown. */
#define PM_ERR_STATE (-7)
```

外加一段散文說明「攔到例外時各類回傳值的哨兵」（指標→NULL、計數／錯誤碼→−6、`pm_age`→−6.0、`pm_occupancy_mask`→0、void→無聲吞下），以及「庫在任何情況下不終止宿主進程」這句承諾。散文用一個哨兵詞（如 `PM_ERR_INTERNAL`）讓測試釘住，手法同既有的 `right-handed`／`0xRRGGBBAA`。

`PM_ABI_VERSION` 不動、`.def` 不動（沒有新符號）、既有的 31 個宣告一個位元都不改。

Haskell 側比照 `pmErrQuota` 的既有寫法，在同一組常數宣告加 `pmErrInternal`、`pmErrState` 並匯出。

### 4. C# 綁定

`bindings/csharp/ParticleMagic.cs` 的常數區加兩行，格式必須是 `public const int Name = Value;   // PM_MACRO …`——`test/BindingContractSpec.hs` 是**用行尾註解的巨集名當鍵**做雙向集合相等的，少一行就紅：

```csharp
public const int ErrInternal = -6;      // PM_ERR_INTERNAL: a bug in the library, never in your call
public const int ErrState = -7;         // PM_ERR_STATE: called out of order
```

### 5. 「刻意觸發內部失敗」的測試路徑

不新增任何對外語意、不加隱藏符號、不讀環境變數。作法是**在測試裡毒化控制代碼的內容物**：`Magic.FFI` 已經匯出 `SpellCell (..)` 與 `SceneCell (..)`（newtype over `IORef ActiveSpell` ／ `IORef Scene`），所以測試可以

```haskell
poisoned <- newStablePtr . SpellCell =<< newIORef (error "poisoned spell")
```

再把它交給任何吃控制代碼的符號。任何強制求值的路徑（`pm_advance` 的 `$!`、`pm_observe` 對 `batches (observeSpell …)` 的 poke、`pm_age` 的 `evaluate`）都會在防火牆內拋 `ErrorCall`。

這條路徑只存在於測試檔，產品程式碼零改動、零新語意，也不需要任何建置旗標。

**限制**：純 C 的 out-of-process 宿主造不出毒化控制代碼，所以 F006 oop-load-smoke 的「同一程式驗證防火牆」需要另一個觸發機制。本功能不做，見「待確認假設 A3」。

### 6. 合併順序（涵蓋「之後新增的符號」）

守門測試**不寫死符號清單**：它從 `src/ffi/Magic/FFI.hs` 動態列舉 `foreign export ccall <name>`（手法同 `test/FFIContractSpec.hs` 的 `foreignExports`），再對每個名字取它的定義塊（自 `^<name> ` 起、到下一個頂層定義為止），斷言塊內出現 `firewall` 或 `firewallErr`。

因此：

- **本功能先合併**時，F005 新增 `pm_plan_steps`／`pm_advance_ex`／`pm_scene_advance_ex` 而沒包防火牆，測試會紅——這正是要的行為，F005 只需在自己的定義上加一個組合子呼叫。
- **F005 先合併**時，本功能的逐符號套用要多包三個；因為套用是「等號右側最外層插一個呼叫」，機械且無邏輯衝突。
- 與 F002 的衝突面同理：F002 改的是控制代碼解析（`withCell`／`withScene` 的內部），本功能加的是最外層，只有縮排會撞。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `writeErr :: CString -> CInt -> String -> IO ()` | `src/ffi/Magic/FFI.hs:1320` | - | 攔截時把例外文字寫進宿主的 `err_buf`；已保證截斷安全、`NULL`／`len <= 0` 無操作 |
| `pmOk, pmErrJson, pmErrBudget, pmErrCapacity, pmErrArgs, pmErrQuota :: CInt` | `src/ffi/Magic/FFI.hs:205-221` | - | 新常數 `pmErrInternal`／`pmErrState` 比照同一處宣告、同一組匯出 |
| `nullSpell :: StablePtr SpellCell` | `src/ffi/Magic/FFI.hs:296` | - | 回傳指標的兩個符號之一的哨兵 |
| `nullScene :: StablePtr SceneCell` | `src/ffi/Magic/FFI.hs:321` | - | 同上（`pm_scene_new`） |
| `newtype SpellCell = SpellCell (IORef ActiveSpell)`（構造子已匯出） | `src/ffi/Magic/FFI.hs:290` | - | 測試毒化控制代碼；產品程式碼不動它 |
| `newtype SceneCell = SceneCell (IORef Scene)`（構造子已匯出） | `src/ffi/Magic/FFI.hs:317` | - | 同上（場景側） |
| 29 個 `foreign export ccall` 的定義與簽名（`pm_abi_version :: IO CInt` … `pm_depth_order :: CInt -> Ptr CFloat -> Ptr CFloat -> Ptr CFloat -> CInt -> Ptr CInt -> IO CInt`） | `src/ffi/Magic/FFI.hs:336-1221` | - | 逐一在最外層插入組合子；簽名一個都不改 |
| `try :: Exception e => IO a -> IO (Either e a)` | `base`（GHC 9.14.1，`Control.Exception`；以 `ghc -e ':t'` 實查） | - | 攔截本體 |
| `evaluate :: a -> IO a` | `base`，`Control.Exception` | - | 在 `try` 範圍內把結果強制到 WHNF，堵住 thunk 逃逸 |
| `displayException :: Exception e => e -> String` | `base`，`Control.Exception` | - | 例外文字 |
| `SomeException :: (Exception e, HasExceptionContext) => e -> SomeException` | `base`，`Control.Exception` | - | 攔截型別（GHC 9.14 的構造子帶 `HasExceptionContext`，只在型別註記處用得到型別本身） |
| `headerDefines :: IO [(String, Int)]`、`headerFunctions :: IO [String]`、`readUtf8 :: FilePath -> IO String` | `test/FFIContractSpec.hs:314, 283, 351`（已匯出給 `BindingContractSpec` 用） | - | 新測試沿用標頭剖析，不做第二份 |
| `castOk :: BS.ByteString -> CastContext -> IO (StablePtr SpellCell)`、`observeRaw :: StablePtr SpellCell -> Int -> Int -> IO Observed`、`data Observed { obPosX, obPosY, obPosZ, obSize, obLife, obColor, obInfo }` | `test/FFIHarness.hs:111, 155, 128-136` | - | T7 的「合法輸入逐位元不變」回歸 |
| `it "mirrors every header constant, by name and by value"`（雙向集合相等，鍵為 C# 行尾註解裡的巨集名） | `test/BindingContractSpec.hs:41-48` | - | C# 常數同步的既有守門；本功能加 `#define` 就必須同步加 C# 常數，否則此測試紅 |
| `it "agrees with Haskell on every error code"` 的期望表 | `test/FFIContractSpec.hs:142-152` | - | 兩個新錯誤碼加入此表 |
| `foreign-library particle-magic-ffi` 的 `build-depends` 白名單：`base`、`magic-boundary`、`bytestring`、`vector`（由 `FFIContractSpec` 斷言） | `particle-magic.cabal` | - | 防火牆只准用 `base`；不得引入 `safe-exceptions`／`deepseq` |

## 新增的介面

### C 面（`include/particle_magic.h`，只加不改）

| 名稱 | 值 | 說明 |
|---|---|---|
| `PM_ERR_INTERNAL` | `(-6)` | 防火牆攔到的一切；庫內部缺陷，宿主無需重試，進程不受影響 |
| `PM_ERR_STATE` | `(-7)` | 宿主呼叫順序錯（未初始化就呼叫、關閉後再初始化、重複帶設定初始化、設定在當前平台無法生效）。本功能只加常數，語意由 F003／F004 落地 |

**無新符號、無新結構、`PM_ABI_VERSION` 不動、`.def` 不動。**

### Haskell 面（`Magic.FFI`；非 C 契約的一部分，比照 `writeErr` 匯出給測試）

| 簽名 | 說明 |
|---|---|
| `pmErrInternal :: CInt` | `-6`，`PM_ERR_INTERNAL` 的 Haskell 面鏡像 |
| `pmErrState :: CInt` | `-7`，`PM_ERR_STATE` 的 Haskell 面鏡像 |
| `firewall :: a -> IO a -> IO a` | 哨兵 ＋ 受保護的動作；攔到一切 `SomeException`，結果強制到 WHNF 後回傳 |
| `firewallErr :: CString -> CInt -> a -> IO a -> IO a` | 同上，外加把例外文字寫進 `err_buf`（截斷安全）。`firewall` 是它 `nullPtr 0` 的特例 |

### C# 面（`bindings/csharp/ParticleMagic.cs`）

| 名稱 | 值 | 說明 |
|---|---|---|
| `Pm.ErrInternal` | `-6` | 行尾註解必須是 `// PM_ERR_INTERNAL …` |
| `Pm.ErrState` | `-7` | 行尾註解必須是 `// PM_ERR_STATE …` |

## TodoList

- [ ] T1: `Magic.FFI` 新增並匯出 `pmErrInternal = -6`、`pmErrState = -7`，比照 `pmErrQuota` 的宣告與註解風格  `dep: -`
- [ ] T2: `include/particle_magic.h` 新增兩個 `#define` 與「防火牆哨兵」散文段落（含「庫在任何情況下不終止宿主進程」與 `pm_is_finished` 回 −6 的解釋）；`PM_ABI_VERSION` 與既有 31 個宣告不動  `dep: T1`
- [ ] T3: 實作 `firewall` / `firewallErr` 兩個組合子（`try` ＋ `evaluate` ＋ 取訊息的二次保護），並加入模組的 Internals 匯出區；新測試模組登記進 `particle-magic.cabal` 的 `test-suite spec` `other-modules`  `dep: T1`
- [ ] T4: 讓 `firewallErr` 在攔截時把 `"internal error: …"` 寫進 `err_buf`，沿用 `writeErr` 的 UTF-8 截斷；`NULL` 緩衝與 `len <= 0` 為無操作  `dep: T3`
- [ ] T5: 29 個匯出符號逐一在等號右側最外層套上組合子，依「哨兵表」選哨兵；帶 `err_buf` 的四個用 `firewallErr`；不動任何簽名與既有邏輯  `dep: T3, T4`
- [ ] T6: 毒化控制代碼的行為驗證：22 個吃控制代碼的符號各自回哨兵、進程存活（`pm_free`／`pm_scene_free` 不強制求值，斷言其為安全的無操作）  `dep: T5`
- [ ] T7: 合法輸入的輸出逐位元不變的回歸（`pm_observe` 六欄與 `batch_info` 對照 `Magic.Interface` 參考路徑）  `dep: T5`
- [ ] T8: `bindings/csharp/ParticleMagic.cs` 新增 `ErrInternal`／`ErrState` 兩個常數，行尾註解帶巨集名  `dep: T2`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `FFIContractSpec` — `it "pins the internal and state codes at -6 and -7, on both sides"` | `pmErrInternal == -6`、`pmErrState == -7`，且與標頭 `#define` 相等；並把兩者加進既有的 `"agrees with Haskell on every error code"` 期望表 |
| T2 | `FFIContractSpec` — `it "documents the firewall's sentinels and keeps PM_ABI_VERSION at 1"` | 標頭含哨兵詞 `PM_ERR_INTERNAL` 的散文段落；`PM_ABI_VERSION` 仍為 1；`headerFunctions` 的集合與既有 31 個相等（沒有偷加符號） |
| T3 | `FFIFirewallSpec` — `it "maps every kind of Haskell exception to the sentinel"` | 對 `throwIO`（自訂例外）、`error`（`ErrorCall`）、`undefined`、以及「回傳值是 thunk 才爆」四種動作各跑一次 `firewall`，皆回哨兵且不拋出；第四種即 `evaluate` 的回歸（拿掉 `evaluate` 就會逃逸） |
| T4 | `FFIFirewallSpec` — `it "writes the exception text into err_buf, truncation safe"` | 攔截後緩衝內是 NUL 結尾的合法 UTF-8、含例外文字、未寫過 `err_len`（沿用 `FFIErrorSpec` 的護欄位元組手法）；`NULL` 緩衝與 `len == 0` 不寫任何位元組 |
| T5 | `FFIFirewallSpec` — `it "every foreign export goes through the firewall (source audit)"` | 自 `src/ffi/Magic/FFI.hs` 動態列舉 `foreign export ccall`，逐一取其定義塊並斷言塊內出現 `firewall` 或 `firewallErr`；清單不寫死，之後新增的符號自動納管 |
| T6 | `FFIFirewallSpec` — `it "every handle-taking symbol answers its sentinel for a poisoned handle"` | 表驅動：毒化的 `SpellCell`／`SceneCell` 餵給 22 個吃控制代碼的符號，斷言 −6／−6.0／0／NULL／無聲返回，且測試進程存活到最後一條 |
| T7 | `FFIFirewallSpec` — `it "legal input is bit-identical with the firewall in place"` | 用 `FFIHarness.castOk` ＋ `observeRaw` 取一個出貨範例陣的六欄與 `batch_info`，與 `Magic.Interface` 參考路徑逐位元比對（`Float` 以位元樣式比，不用近似）；既有 `FFIObserveSpec`／`Acceptance9Spec`／`FFISpaceSpec` 保持綠是同一條的旁證 |
| T8 | `BindingContractSpec` — `it "mirrors every header constant, by name and by value"`（既有測試，須綠） | 雙向集合相等：兩個新 `#define` 若沒有對應的 C# 常數（或註解沒帶巨集名）即紅 |

## 待確認假設

- **A1**: `pm_age`（`IO CDouble`）沒有錯誤碼通道，委派決策只涵蓋指標／計數／void 三類 → 採取：哨兵為 `-6.0`（`PM_ERR_INTERNAL` 的浮點鏡像；年齡恆為非負，所以負值無歧義），並寫進標頭 → 影響：若改用 NaN 或 0，要改哨兵表、T6 的期望值與標頭那一句；NaN 會污染宿主時鐘、0 會與「剛施法」混淆，這是選 −6.0 的理由。
- **A2**: `pm_occupancy_mask`（`IO Word32`）無負值可用 → 採取：哨兵為 `0`，與既有「`NULL` 控制代碼回 0」「空法術回 0」一致，且在重疊測試上是 fail-safe（回報「哪裡都沒有」而非「到處都有」）→ 影響：若改用 `0xFFFFFFFF`（因標頭保證 bits 27..31 恆為 0，該值不可能合法，可被宿主辨識），要改哨兵表、T6 期望值與標頭敘述。
- **A3**: 契約卡的「一條刻意觸發內部失敗的測試路徑」在 in-process 以毒化控制代碼滿足；純 C 的 out-of-process 宿主（F006 的驗收標準明文要求「同一程式驗證防火牆」）造不出毒化控制代碼 → 採取：本功能只交付 in-process 觸發路徑，不新增任何對外語意、隱藏符號或環境變數開關；建議 F006 以「建置旗標（cabal flag）產出的測試專用共享函式庫，額外匯出一個必定拋例外的符號」解決，該符號不進標頭、不進 `.def` 的出貨版本 → 影響：若編排者裁定要讓出貨版本也能被 C 觸發，本功能要多加一個匯出符號、標頭一條宣告與 `.def` 一行，`FFIContractSpec` 的三方對帳全部跟著動。已評估並否決的替代：靠深度巢狀 JSON 誘發堆疊溢位（跨平台不可重現）、靠 `pm_occupancy` 的巨大 `dim` 誘發堆積耗盡（機器夠大時反而會寫爆宿主緩衝）。
- **A4**: 「攔截一切 Haskell 例外」是否包含非同步例外 → 採取：以 `SomeException` 全攔、不重拋（ADR-022 D2 的字面意思；C 邊界上沒有「稍後重拋」的地方，讓 `ThreadKilled` 穿出去就等於殺進程）→ 影響：若日後要讓某類非同步例外穿透（例如宿主用 `hs_try_putmvar` 之類的取消機制），要在組合子裡加型別過濾，T3 要多一條「某類例外不被吞」的斷言。
- **A5**: 防火牆路徑與 all-or-nothing 承諾的關係 → 採取：明文不承諾——例外若發生在複製途中，宿主緩衝可能半更新，庫只承諾「不崩、回哨兵」→ 影響：若編排者要求防火牆也維持 all-or-nothing，觀測類符號必須先寫暫存再整塊搬，與 F010 block-copy-out 的設計直接衝突，應改為那份文檔的議題。
- **A6**: 兩個組合子的命名（`firewall`／`firewallErr`）與「從 Internals 區匯出」的決定 → 採取：固定下來，因為 T5 的原始碼守門測試要靠名字比對，T3／T4 要直接呼叫它們 → 影響：改名要同步改守門測試的比對字串；這是實作自主權讓渡給可測性的一次刻意取捨。
- **A7**: ADR-022 背景第 1 條寫「30 個 `foreign export`」，實查為 **29** 個（`src/ffi/Magic/FFI.hs` 有 30 行含 `foreign export ccall`，其中一行是模組 haddock 的引文）；31 個凍結符號 ＝ 29 個 Haskell 匯出 ＋ `pm_init`／`pm_shutdown` 兩個 C 函式，與標頭的 31 條宣告、`.def` 的 31 行相符 → 採取：本文件一律以 29／31 敘述 → 影響：ADR-022 的那個數字建議由編排者修訂（純敘述修正，不動任何決策）。

## 實作備註

（撰寫時留空）
