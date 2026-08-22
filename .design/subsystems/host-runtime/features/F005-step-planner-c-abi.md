---
id: F005
type: feature
title: step-planner-c-abi
description: 時步規劃器上 C 面,推進拒收非有限或負的步長
status: done
created: 2026-08-20
updated: 2026-08-21
depends-on: []
related-adr: [ADR-022]
related-feature: []
---

# F005: 時步規劃器上 C 面

## 功能概述

宿主拿到共享函式庫之後,**固定時步的正確實作只有 Haskell 面能用**。累加器、單幀最大步數截斷(死亡螺旋防護)與浮點 epsilon 全部住在邊界層的 `Magic.Step.plan`,C ABI 沒有匯出它;出貨的 C 與 C# 範例都是宿主自己手寫的 `while (accumulator >= FIXED_DT)`,**沒有截斷**——一次關卡載入的 hitch 會讓宿主對同一個法術連呼叫數百次推進(ADR-022 背景 4)。同時 `dt` 完全不檢查:NaN 的 `dt` 讓法術時鐘永久中毒,`pm_is_finished` 永遠回 0,宿主的 `while (!pm_is_finished)` 卡死(背景 5)。

本功能把**同一份**規劃器搬上 C 面,並給推進補上 `dt` 檢查。兩件事都是加法:既有 31 個符號一個位元都不動。

**驗收標準**(承 `design.md` 的 step-planner-c-abi 契約卡):

1. C 面的時步規劃器(雙精度參數與累加器)與 Haskell 面對同一輸入序列給出**逐位元相同**的步數與累加器,含截斷與 epsilon 兩種情況。
2. 推進對 NaN、無限大、負值回 `PM_ERR_ARGS` 且年齡不變;`dt == 0` 是合法的空操作。
3. 合法步長的輸出逐位元不變(既有 `Acceptance9Spec` 的跨界等價律保持綠)。

**明確不做**:不在推進內建累加器(所有權留在宿主,ADR-022 D5);不改變既有推進符號的簽名;不處理宿主範例與 `docs/integration.md` 的改寫(屬 F008 host-doc-corrections)。

### 為什麼「同一份實作」不能靠複製

C1.7 要求「與 boundary-host 的時步規劃器**同一份實作**、逐位元相同」。`Magic.Step` 已經在 `magic-boundary` 的 `exposed-modules` 裡(`particle-magic.cabal:95`),而 foreign-library 的 `build-depends` 已含 `particle-magic:magic-boundary`(`particle-magic.cabal:243`),所以 `Magic.FFI` 只要多一行 `import Magic.Step (StepPlan (..), plan)` 就構得到——**不需要動 cabal 的依賴白名單**,`FFIContractSpec` 那條白名單斷言(`base`/`magic-boundary`/`bytestring`/`vector`)照舊綠。C 面因此是一層純粹的型別穿越,逐位元等價**由建構保證**,測試是防止未來有人改寫成第二份拷貝的守門。

推論:`pm_plan_steps` 是 Haskell 匯出,因此**需要 RTS 已啟動**(`pm_init`)。「純函數卻要先 init」是刻意的取捨——把它寫進 cbits 用 C 重寫一遍就會製造第二份真相,違反 C1.7。標頭必須明說這件事。

## 相依性

`depends-on: []`——本功能**可與 W1 的其他四項完全平行開發**。理由:介面表裡每一列的來源文檔都是 `-`(全是既有、已交付的程式碼),沒有任何一列指向進行中的文檔。

與三個平行進行中的 feature 的**合併關係**(不是相依,是同一批符號會被它們涵蓋,先落地者不阻塞後落地者):

| 平行項 | 合併關係 |
|---|---|
| F001 exception-firewall | F001 的驗收標準是「每一個匯出符號都經由防火牆」。本功能新增的三個符號在 F001 落地後**自動被它涵蓋**;先落地者不必替對方預留鉤子。若 F005 先合併,F001 的清單要包含這三個新名字;若 F001 先合併,本功能的三個符號實作時直接套用 F001 已建立的防火牆包裝 |
| F002 handle-generation | `pm_advance_ex` / `pm_scene_advance_ex` 的控制代碼解析走**當時 `Magic.FFI` 既有的解析路徑**(今天是 `withCell` / `withScene`)。F002 把它換成世代標籤註冊表時,這兩個新符號跟著換,行為從「NULL 容忍」收斂為「無效控制代碼回 `PM_ERR_ARGS`」——與本功能對 NULL 的裁決(見 A3)方向一致,不衝突 |
| F003 rts-config-init | F003 建立 I3(RTS 未初始化就呼叫任何符號回 `PM_ERR_STATE`)。`pm_plan_steps` 是 Haskell 匯出,因此**也在 I3 的管轄內**;本功能不自己實作狀態檢查,只在標頭寫明「呼叫前需 `pm_init`」,錯誤碼由 F003 統一補上 |
| F008 host-doc-corrections | 本功能只提供符號;範例與整合指南改用它是 F008 的驗收標準(`design.md` 功能規劃 #8 依賴 #5)。本功能**不動** `examples/`、`docs/integration.md` |

## 對應的 Level 2 契約

逐條確認未超出 `design.md` 的範圍:

| 契約 | 本功能怎麼實作 | 是否在範圍內 |
|---|---|---|
| **C1.7 時步規劃** | 「純函數:(步長、單幀最大步數、經過時間、累加器)→(本幀步數、新累加器)。參數與累加器為雙精度,與 boundary-host 的時步規劃器同一份實作、逐位元相同;既有推進符號的單精度步長簽名不動」→ `pm_plan_steps` 直接轉呼 `Magic.Step.plan`,`double` 對 `Double`,既有 `pm_advance` 的 `float` 不動 | ✅ 完全落在條目內 |
| **C2.6 `dt` 檢查** | 「非有限或負的步長一律不改變狀態;錯誤碼由 C1.12 的變體回報,既有的 `void` 推進符號靜默無操作」 | ✅ 閘門後 C2.6 已改寫,直接對應下方的兩半拆解 |
| **C1.12 推進的錯誤碼變體** | 「鏡射既有推進的加法符號,只多一個錯誤碼通道:非有限或負的步長回 `PM_ERR_ARGS`、無效控制代碼回 `PM_ERR_ARGS`,合法輸入與既有符號逐位元相同」→ `pm_advance_ex` / `pm_scene_advance_ex` | ✅ |
| **C1 只加不改** | 新增三個符號,`PM_ABI_VERSION` 不動,既有 31 個符號的簽名與行為(合法輸入)不變 | ✅ |
| **C1.9 錯誤碼** | 只使用既有的 `PM_OK` 與 `PM_ERR_ARGS`,不新增錯誤碼 | ✅ |
| **I1 M2 → boundary-host** | 「只呼叫邊界層既有條目,不得新增語意」→ `plan` 與 `advanceSpell` / `advanceScene` 都是既有條目;C 面的參數驗證是**參數檢查**(資料流管線的驗證段),不是新語意 | ✅ |
| **資料流管線** | 驗證段(`dt` 與規劃器參數的檢查)與輸入段的時步規劃 | ✅ 契約卡指定的段落 |

### C2.6 的表達問題(已機械查證)

查證結果(`include/particle_magic.h:199` 與 `:337`,`src/ffi/Magic/FFI.hs:432` 與 `:859`):

```c
void pm_advance(PmSpell* spell, float dt);
void pm_scene_advance(PmScene* scene, float dt);
```

兩者都是 `void`,而且在 `FFIContractSpec` 的凍結清單裡。ADR-022 D5 寫的「`pm_advance`／`pm_scene_advance` 對非有限或負的 `dt` 回 `PM_ERR_ARGS`」**在既有簽名上無法成立**——沒有回傳值可以承載錯誤碼,而改簽名會破壞「只加不改」。

裁決(與 A1 對應):把 C2.6 拆成兩半,各由一個機制承擔——

- **「狀態不變」那一半**由既有的兩個 `void` 符號承擔:非有限或負的 `dt` 一律**空操作**,法術年齡一個位元都不變。這只改變「原本就是未定義」的輸入的行為(ADR-022 D5 原文),合法輸入完全不變。
- **「回 `PM_ERR_ARGS`」那一半**由新增的 `pm_advance_ex` / `pm_scene_advance_ex` 承擔,沿用專案既有的 `_ex` 加法慣例(`pm_cast_ex`、`pm_observe_ex`)。

這是唯一能同時滿足 C2.6 與「只加不改」的作法。**裁決已落地**:`design.md` 已補上 **C1.12 推進的錯誤碼變體**,C2.6 也改寫為「錯誤碼由 C1.12 的變體回報,既有的 `void` 推進符號靜默無操作」,兩個新符號因此有明文歸屬。

## 實作方式

### 一、`pm_plan_steps`

`src/ffi/Magic/FFI.hs` 新增匯出,型別穿越 + 參數檢查 + 轉呼:

```
pm_plan_steps dt max_steps elapsed acc_in outSteps outAcc
  ├ 驗證(任一不過 → 回 pmErrArgs,兩個出參一個位元組都不寫)
  │   1. outSteps == nullPtr || outAcc == nullPtr
  │   2. dt、elapsed、acc_in 任一為 NaN 或 ±Infinity
  │   3. max_steps < 0
  │   4. acc_in < 0
  ├ StepPlan n acc' = plan (cdoubleToDouble dt) (fromIntegral max_steps)
  │                        (cdoubleToDouble elapsed) (cdoubleToDouble acc_in)
  └ poke outSteps (fromIntegral n) >> poke outAcc (CDouble acc') >> pure pmOk
```

`CDouble` 是 `Double` 的 newtype,拆包即轉,**不經 `realToFrac`**——與既有 `cfloatToDouble`(`FFI.hs:1310`)同一個理由:`realToFrac` 走 `Rational`,會把 NaN 與無限大改壞。驗證已經把非有限值擋在外面,但拆包仍是唯一保證逐位元的寫法。

#### 驗證規則 2–4 的依據(以 `ghc -e` 對真實 `plan` 實測;規則 1 的 NULL 檢查不需佐證)

| 輸入 | `Magic.Step.plan` 的實際結果 | 為什麼要在 C 面擋掉 |
|---|---|---|
| `plan NaN 8 0.5 0.25` | `StepPlan 0 0.0` | 步數 0 看似無害,但**累加器被靜默清成 0**——宿主的積壓憑空消失 |
| `plan Inf 8 0.5 0.25` | `StepPlan 0 0.0` | 同上,累加器被清空 |
| `plan (1/60) 8 Inf 0.25` | `StepPlan 0 Infinity` | **累加器被永久毒化**:之後每一幀都算出 0 步,法術從此不動 |
| `plan (1/60) 8 0.5 NaN` | `StepPlan 0 0.0` | 累加器被清空 |
| `plan (1/60) (-3) 0.5 0.25` | `StepPlan (-3) 0.0` | **步數為負**。宿主拿它當迴圈次數 |
| `plan (1/60) 8 0.5 (-0.9)` | `StepPlan (-24) 0.0` | **步數為負** |

(`floor` 在本機 GHC 對 NaN 與 Infinity 都回 0,這是實作定義行為,不該寫進跨平台契約——更是不該把這幾格當成「規劃器的語意」對外承諾的理由。)

**後置條件(可證且必測)**:通過驗證的輸入,`*out_steps ∈ [0, max_steps]` 且 `*out_acc >= 0`。證明:`dt <= 0` 時 `plan` 直接回 `StepPlan 0 acc`;`dt > 0` 且 `acc_in >= 0`、`elapsed` 有限時 `acc' = acc_in + max 0 elapsed >= 0`,故 `n = floor (acc'/dt + ε) >= 0`,而 `n > maxSteps` 時被夾到 `maxSteps`;累加器兩條分支分別是 `0` 與 `max 0 (...)`。

**留在契約內的語意**(不改、不夾、直接鏡射 `Magic.Step.plan`):

- `dt <= 0`(含 `dt == 0` 與負的 `dt`)→ 0 步、累加器原樣退回。這是 `plan` 既有且被 `StepSpec` 測著的語意,C 面不得另立一套。**注意這與 C2.6 對推進的 `dt` 規則不同**:規劃器的負 `dt` 是「不跑」,推進的負 `dt` 是「拒收」——兩者是不同的函數,前者是宿主的設定值,後者是宿主的每幀輸入。
- 負的 `elapsed` → 當成 0(`max 0 elapsed`)。
- 截斷時**丟棄積壓**(累加器歸 0),模擬變慢而非凍結。
- epsilon `1e-9` 吸收時鐘噪音。**C 面不得自己寫一份 epsilon**——它是 `plan` 的 `where` 區域繫結,沒有匯出,這正是「只能轉呼、不能複製」的機械保證。

### 二、`pm_advance_ex` / `pm_scene_advance_ex` 與既有 `void` 推進

共用一個 `dt` 判定:`dt` 為 NaN、`±Infinity` 或 `< 0` 即非法;`dt == 0` 合法(空操作,年齡不變,回 `PM_OK`)。判定在 **`CFloat` 上做**,不先加寬——`cfloatToDouble` 是精確的,兩邊等價,但在原型上判定讀起來就是「宿主給的那個 `float`」。

- `pm_advance_ex`:控制代碼無效(今天:NULL)→ `PM_ERR_ARGS`;`dt` 非法 → `PM_ERR_ARGS` 且 cell **不寫回**;否則走與 `pm_advance` **完全相同**的 `advanceSpell` 路徑並回 `PM_OK`。
- `pm_scene_advance_ex`:同構,走 `advanceScene`。
- 既有 `pm_advance` / `pm_scene_advance`:加同一個判定,非法時**直接返回**(不寫回 cell),簽名與合法路徑一個位元都不動。

實作上兩者共用同一個內部判定函數,**避免兩份規則漂移**(私有函數命名屬實作自主權)。

### 三、三處對帳同步

新增符號必須同時出現在四個地方,否則既有守門測試會紅(這是查證出來的硬約束):

1. `src/ffi/Magic/FFI.hs` 的 `foreign export ccall` 與模組匯出清單。
2. `include/particle_magic.h` 的宣告(`FFIContractSpec` 斷言 header ≡ foreign exports + `pm_init`/`pm_shutdown`)。
3. `particle-magic-ffi.def` 的 `EXPORTS`(`FFIContractSpec` 斷言 def ≡ header)。
4. `bindings/csharp/ParticleMagic.cs` 的 `DllImport`(`BindingContractSpec` 斷言 extern ≡ header,**雙向**)。

另外 `FFIContractSpec` 有一條**寫死的凍結符號清單**(`test/FFIContractSpec.hs:75-112`),新符號必須加進去,否則 `sort exports shouldBe sort [...]` 會紅。ABI 世代不動:`PM_ABI_VERSION` 維持 1。31 → 34 個符號。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `plan :: Double -> Int -> Double -> Double -> StepPlan` | `src/boundary/Magic/Step.hs:27` | - | 唯一的時步規劃實作;`pm_plan_steps` 直接轉呼它 |
| `data StepPlan = StepPlan { stepsToRun :: !Int, accAfter :: !Double }` | `src/boundary/Magic/Step.hs:15-19` | - | 規劃結果的兩個欄位,拆出來寫進宿主的兩個出參 |
| `pm_advance :: StablePtr SpellCell -> CFloat -> IO ()` | `src/ffi/Magic/FFI.hs:435` | - | 既有推進符號;本功能給它加 `dt` 判定,簽名不動,並以它為 `pm_advance_ex` 的本體 |
| `pm_scene_advance :: StablePtr SceneCell -> CFloat -> IO ()` | `src/ffi/Magic/FFI.hs:863` | - | 同上,場景版 |
| `advanceSpell :: FrameInput -> ActiveSpell -> ActiveSpell` | `src/boundary/Magic/Interface.hs:213` | - | 推進的唯一語意來源;`_ex` 變體走同一條路徑才談得上「輸出逐位元不變」 |
| `advanceScene :: FrameInput -> Scene -> Scene` | `src/boundary/Magic/Scene.hs:165` | - | 場景推進的語意來源 |
| `withCell :: StablePtr SpellCell -> b -> (IORef ActiveSpell -> IO b) -> IO b` | `src/ffi/Magic/FFI.hs:302` | - | 控制代碼解析(F002 落地後會換成世代標籤註冊表) |
| `withScene :: StablePtr SceneCell -> b -> (IORef Scene -> IO b) -> IO b` | `src/ffi/Magic/FFI.hs:327` | - | 場景控制代碼解析 |
| `cfloatToDouble :: CFloat -> Double` | `src/ffi/Magic/FFI.hs:1310` | - | `float` → `Double` 的精確加寬(拆 newtype,不經 `Rational`);`CDouble` 的拆包沿用同一個寫法 |
| `spellAge :: ActiveSpell -> Time` | `src/boundary/Magic/Interface.hs:465` | - | 測試斷言「年齡不變」的讀取點(經 `pm_age`) |
| `pmOk, pmErrArgs :: CInt`(`pmOk = 0`,`pmErrArgs = -4`) | `src/ffi/Magic/FFI.hs:205-214` | - | 本功能只用這兩個既有錯誤碼,不新增 |
| `void pm_advance(PmSpell* spell, float dt);` | `include/particle_magic.h:199` | - | 凍結宣告;查證「回傳型別是 `void`」的依據 |
| `void pm_scene_advance(PmScene* scene, float dt);` | `include/particle_magic.h:337` | - | 同上 |
| `headerFunctions :: IO [String]` / `headerDefines :: IO [(String, Int)]` / `readUtf8 :: FilePath -> IO String` | `test/FFIContractSpec.hs:283 / :314 / :351` | - | 三方對帳的既有解析器;`BindingContractSpec` 也用它們,新符號自動進入兩邊的對帳 |
| `castOk`、`referenceSpell`、`spellBytes`、`testCtx` | `test/FFIHarness.hs` | - | 既有的 in-process C ABI 測試骨架;推進守衛測試以它取得真實控制代碼 |

全部十五列的「來源文檔」都是 `-`:本功能只消費**已交付**的程式碼,沒有一列指向進行中的文檔。

## 新增的介面

### C 面(`include/particle_magic.h`,加法)

```c
/* Plan a frame's fixed steps. Pure: it reads and writes nothing but its
   own arguments, and is the same implementation the Haskell side uses,
   so a host that drives its loop with this gets bit-identical stepping.

   Double precision on purpose: a float accumulator drifts, and the
   library's planner is double. pm_advance's float dt is unaffected.

   dt <= 0 plans zero steps and hands the accumulator back untouched.
   A negative elapsed reads as zero. When the backlog exceeds max_steps
   the plan clamps and DROPS the rest (the simulation slows down instead
   of freezing).

   Returns PM_OK, or PM_ERR_ARGS -- writing nothing at all -- when either
   out pointer is NULL, when dt, elapsed or acc_in is not finite, when
   max_steps is negative, or when acc_in is negative. On PM_OK,
   *out_steps is in [0, max_steps] and *out_acc is >= 0.

   Needs the runtime: call pm_init() first, as for every other entry
   point here. */
int pm_plan_steps(double dt, int max_steps, double elapsed, double acc_in,
                  int* out_steps, double* out_acc);

/* pm_advance with the argument check reported: returns PM_OK, or
   PM_ERR_ARGS -- leaving the spell's clock untouched -- for a NULL or
   invalid handle and for a dt that is NaN, infinite or negative. A dt of
   0 is legal and is a no-op. The void pm_advance above is unchanged for
   every legal dt and is likewise a no-op for an illegal one; it simply
   has no way to say so. */
int pm_advance_ex(PmSpell* spell, float dt);

/* pm_scene_advance with the same check. */
int pm_scene_advance_ex(PmScene* scene, float dt);
```

出參命名用 `out_steps` / `out_acc`,與標頭既有的 `out_spell`、`out_ids`、`out_used`、`out_cap`、`out_min` 一致(參數名不是 ABI 的一部分)。

### Haskell 面(`src/ffi/Magic/FFI.hs`,加法)

```haskell
foreign export ccall pm_plan_steps
  :: CDouble -> CInt -> CDouble -> CDouble -> Ptr CInt -> Ptr CDouble -> IO CInt

pm_plan_steps
  :: CDouble -> CInt -> CDouble -> CDouble -> Ptr CInt -> Ptr CDouble -> IO CInt

foreign export ccall pm_advance_ex :: StablePtr SpellCell -> CFloat -> IO CInt
pm_advance_ex :: StablePtr SpellCell -> CFloat -> IO CInt

foreign export ccall pm_scene_advance_ex :: StablePtr SceneCell -> CFloat -> IO CInt
pm_scene_advance_ex :: StablePtr SceneCell -> CFloat -> IO CInt
```

模組匯出清單(`Magic.FFI` 的 export list)同步加這三個名字。**不新增任何常數**,不新增錯誤碼,`pmAbiVersion` 不動。

### C# 綁定(`bindings/csharp/ParticleMagic.cs`,加法)

三個對應的 `[DllImport]` extern,型別對照 `double`→`double`、`int`→`int`、`int*`→`out int`/`ref int`、`double*`→`out double`(既有綁定的慣例為準)。**不新增 `public const int`**——本功能沒有新的 `#define`,`BindingContractSpec` 的常數雙向對帳因此不受影響。

## TodoList

- [x] T1: `Magic.FFI` 新增 `pm_plan_steps`(`import Magic.Step (StepPlan (..), plan)`,直接轉呼,零演算法複製) `dep: -`
- [x] T2: `pm_plan_steps` 的四條參數驗證,失敗回 `PM_ERR_ARGS` 且兩個出參一個位元組都不寫 `dep: T1`
- [x] T3: 逐位元等價律:同一輸入序列下 C 面與 `Magic.Step.plan` 的步數與累加器完全相同(含截斷與 epsilon) `dep: T1, T2`
- [x] T4: 新增 `pm_advance_ex` / `pm_scene_advance_ex`:非法 `dt` 與無效控制代碼回 `PM_ERR_ARGS` 且狀態不變,`dt == 0` 為合法空操作 `dep: -`
- [x] T5: 既有 `pm_advance` / `pm_scene_advance` 對非法 `dt` 改為空操作(狀態不變),簽名與合法路徑不動 `dep: T4`
- [x] T6: 三個新符號同步進 `include/particle_magic.h`、`particle-magic-ffi.def` 與 `FFIContractSpec` 的凍結清單,`PM_ABI_VERSION` 不動 `dep: T1, T4`
- [x] T7: `bindings/csharp/ParticleMagic.cs` 新增三個 `DllImport` `dep: T6`
- [x] T8: 兩個新測試模組登記進 `particle-magic.cabal` 的 `test-suite spec` 的 `other-modules`,`cabal test` 全綠(含既有 `Acceptance9Spec` 與 `StepSpec` 無回歸) `dep: T3, T5, T6, T7`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `FFIStepPlanSpec` — "plans a typical 60Hz frame exactly as Magic.Step.plan does" | 以 `(dt=1/60, max=8, elapsed=1/30, acc=0)` 呼叫 `pm_plan_steps`,斷言 `*out_steps == 2`、`*out_acc` 與 `accAfter (plan …)` 相同;證明轉呼接通且出參寫對位置 |
| T2 | `FFIStepPlanSpec` — "rejects bad arguments with PM_ERR_ARGS and writes nothing" | 逐一測 NULL 出參(兩個各一次)、`dt`/`elapsed`/`acc_in` 各為 NaN 與 `±Inf`、`max_steps = -1`、`acc_in = -0.5`:回 `pmErrArgs`,且預填哨兵的出參**位元不變**(仿 `FFIHarness` 的 sentinel 手法) |
| T3 | `FFIStepPlanSpec` — "is bit-identical to Magic.Step.plan over a frame sequence" (QuickCheck) | 隨機產生合法輸入序列(含 `dt=1/64` 的 dyadic 切片、觸發截斷的長 hitch、以 `iterate (+dt)` 差分出的噪音幀),逐幀把累加器接回下一幀,兩條路徑的 `steps` 與 `acc` 以 `castDoubleToWord64` **逐位元**比對;另斷言後置條件 `steps ∈ [0, max_steps]` 與 `acc >= 0` |
| T4 | `FFIAdvanceGuardSpec` — "the _ex advances reject non-finite and negative dt, leaving the age untouched" | 施法後記錄 `pm_age`,對 NaN、`+Inf`、`-Inf`、`-0.016` 各呼叫一次 `pm_advance_ex`:回 `pmErrArgs` 且 `pm_age` 逐位元不變;`dt = 0` 回 `pmOk` 且年齡不變;`dt = 1/60` 回 `pmOk` 且年齡等於 `advanceSpell` 的參考值。場景版以 `pm_scene_advance_ex` 同構測一次 |
| T5 | `FFIAdvanceGuardSpec` — "the void advances are no-ops on an illegal dt and unchanged on a legal one" | 同一組非法 `dt` 打 `pm_advance` / `pm_scene_advance`,斷言 `pm_age` 與 `pm_is_finished` 逐位元不變(今天 NaN 會讓年齡變 NaN、`pm_is_finished` 永遠回 0,這條就是那個缺陷的回歸測試);再跑一段合法序列,斷言與 `referenceSpell` 的年齡完全相同 |
| T6 | `FFIContractSpec`(既有,擴充) — 三方對帳 | header ≡ foreign exports + cbits 對、def ≡ header、凍結清單含 `pm_plan_steps` / `pm_advance_ex` / `pm_scene_advance_ex`;`PM_ABI_VERSION` 仍為 1;foreign-library 依賴白名單未變 |
| T7 | `BindingContractSpec`(既有) — C# 綁定雙向對帳 | 綁定的 extern 集合與標頭函式集合相等(雙向),`DllImport` 數量相符;常數對帳不受影響 |
| T8 | `cabal test` 全綠(含 `Acceptance9Spec`、`StepSpec`、`ExampleHostSpec` 無回歸) | 「合法步長的輸出逐位元不變」的總驗收:既有的跨界等價律(120 幀不規則 cadence、每個出貨範例陣)與規劃器性質測試在本輪之後仍然綠 |

## 待確認假設

- **A1**: ADR-022 D5 與 C2.6 說「`pm_advance`／`pm_scene_advance` 對非有限或負的 `dt` 回 `PM_ERR_ARGS`」,但查證後兩者的凍結回傳型別都是 `void`(`include/particle_magic.h:199`、`:337`),無法承載錯誤碼,而改簽名違反「只加不改」。→ **採取**:把 C2.6 拆成兩半——既有 `void` 符號承擔「狀態不變」(非法 `dt` 為空操作),新增 `pm_advance_ex` / `pm_scene_advance_ex` 承擔「回 `PM_ERR_ARGS`」,沿用 `pm_cast_ex` / `pm_observe_ex` 的加法慣例。→ **影響**:若編排者裁決不新增 `_ex` 變體,則 C2.6 的錯誤碼半邊在階段一無法交付(只剩空操作),T4/T6/T7 的三分之二要拿掉,符號數維持 32(只加 `pm_plan_steps`);反之若裁決「既有 `void` 符號維持現狀、只有 `_ex` 檢查」,則 T5 要拿掉,但那會讓沒改用 `_ex` 的既有宿主繼續被 NaN 毒化。**另建議** `design.md` 的 C1 表格補一列(如「C1.12 推進的錯誤碼變體」)或在 C2.6 加註,讓這兩個符號有明文歸屬。
- **A2**: `pm_plan_steps` 對「非有限輸入」與「會產生負步數的輸入」的處理,契約卡與 C1.7 都沒有規定,而 `Magic.Step.plan` 在這些輸入上會靜默清空或毒化累加器、或回負的步數(已用 `ghc -e` 對真實函數實測,結果列於「實作方式」)。→ **採取**:C 面對 NULL 出參、`dt`/`elapsed`/`acc_in` 非有限、`max_steps < 0`、`acc_in < 0` 回 `PM_ERR_ARGS` 且不寫出參;其餘全部逐位元鏡射 `plan`,**包含 `dt <= 0 → 0 步、累加器原樣退回`**(不與 C2.6 對推進的負 `dt` 規則對齊——規劃器與推進是不同的函數,前者的 `dt` 是宿主的設定值,後者是每幀輸入)。逐位元等價律的測試域因此是「通過驗證的輸入」。→ **影響**:若裁決「規劃器的負 `dt` 也要拒收」,T2 多一條規則、T3 的產生器縮一格;若裁決「完全不驗證、原樣鏡射」,T2 整條拿掉,但宿主會拿到負的步數當迴圈次數。
- **A3**: `pm_advance_ex` 對 NULL 控制代碼的回應無明文。既有 `pm_advance` 容忍 NULL(空操作),但 `pm_cast_ex` / `pm_observe` 對 NULL 指標回 `PM_ERR_ARGS`。→ **採取**:`_ex` 變體對 NULL 控制代碼回 `PM_ERR_ARGS`(既有 `void` 符號的 NULL 容忍不變),與 F002 把無效控制代碼收斂為 `PM_ERR_ARGS` 的方向一致。→ **影響**:若 F002 最終裁決 NULL 仍是容忍的空操作,`_ex` 要改回 `PM_OK`,只影響 T4 的一條斷言。
- **A4**: `pm_plan_steps` 是 Haskell 匯出,因此需要 RTS 已啟動——一個「純函數」卻要求先 `pm_init`。替代作法是在 `cbits/` 用 C 重寫一份,但那會製造第二份實作,直接違反 C1.7 的「同一份實作」。→ **採取**:維持 Haskell 匯出,標頭明文寫「呼叫前需 `pm_init()`」,未初始化時的錯誤碼(`PM_ERR_STATE`)交給 F003 的 I3 統一補上,本功能不自己實作狀態檢查。→ **影響**:若編排者要求規劃器必須在 RTS 之外可用,C1.7 的「同一份實作」就得改寫成「以測試守護的兩份實作」,本功能的實作方式要整段重寫。
- **A5**: 有一類**全部有限**的輸入仍會讓 `plan` 給出病態結果:`plan 1e-300 8 1e300 0` 回 `StepPlan 0 1e300`(比值溢位成 `Infinity`,`floor` 回 0),即「積壓大到爆表反而一步都不跑」。→ **採取**:**不處理**,逐位元鏡射。理由是它屬於 `Magic.Step.plan` 自己的語意缺口,C 面若自作主張就違反 I1 的「不得新增語意」;而真實宿主的 `dt` 不會是 `1e-300`。→ **影響**:若判斷這是缺陷,應在 boundary-host／particle-simulation 開一份 bugfix 修 `Magic.Step.plan`,C 面自動跟著修正,本文檔不需改。

## 實作備註

實作於 2026-08-21,`cabal test` **1831 examples, 0 failures**(基線 1816,新增 15:`FFIStepPlanSpec` 9 條、`FFIAdvanceGuardSpec` 6 條)。既有測試沒有一條變紅;下列四處是為了讓既有守門測試對上新符號而**必須**改的計數與清單,不是行為變更。

### 一、基底比本文檔撰寫時更晚(F001/F002/F003 已合併),對帳從三處變成五處

本文檔「三處對帳同步」那一節寫於 F003 落地之前。實際落地時新符號有五重義務,缺一測試即紅:

| # | 位置 | 為什麼 |
|---|---|---|
| 1 | `src/ffi/Magic/FFI.hs` 的 `foreign export ccall "pm_hs_*"` | F003 把 29 個匯出全部改成具名 `pm_hs_*`;守門等式是 `foreignExportSymbols ≡ pm_hs_ ＋ (headerFunctions \ 三個 lifecycle)`,清單用算的不是寫死的,所以新符號「因為存在而入列」 |
| 2 | `cbits/pm_gate.c` 的閘門包裝(前向宣告＋`extern` 宣告＋函式本體) | I3:未初始化時回 `PM_ERR_STATE`。三個新符號都是回 `int` 的計數符號,哨兵一律 `PM_ERR_STATE` |
| 3 | `firewall` / `firewallErr` 組合子 | F001 的原始碼守門逐一讀每個匯出的定義區塊 |
| 4 | `include/particle_magic.h`、`particle-magic-ffi.def` | 既有三方對帳 |
| 5 | `bindings/csharp/ParticleMagic.cs` | `BindingContractSpec` 雙向對帳 |

`build-depends` 白名單未動(`Magic.Step` 本來就在 `magic-boundary` 的 `exposed-modules`,只加了一行 import),`PM_ABI_VERSION` 維持 1。

### 二、既有測試裡被改動的四個數字(全部是「加法造成計數上升」)

- `test/FFIContractSpec.hs`:凍結符號清單 +3;兩處 `length declared` 由 **32 → 35**。注意本文檔 T6 寫的是「31 → 34」,那是漏算了 F003 已加入的 `pm_init_ex`;實際基線是 32。
- `test/FFIFirewallSpec.hs`:`length exports` 由 **29 → 32**。
- `test/FFIFirewallSpec.hs`:毒化控制代碼案例由 **22 → 24**——`pm_advance_ex` 與 `pm_scene_advance_ex` 是吃控制代碼的符號,而該條測試的標題就是「每一個吃控制代碼的符號都要對毒化控制代碼回自己的哨兵」,不加就名不副實。兩者的哨兵是 `PM_ERR_INTERNAL`(有錯誤碼通道),與 `void` 版的「回得來就算過」不同。

### 三、內部實作選擇(屬實作自主權,列出僅供閱讀)

- `legalDt :: CFloat -> Bool` 一個私有判定,四個呼叫點(兩個 `void` 推進＋兩個 `_ex`)共用,規則不可能漂移。判定在 `CFloat` 上做,`-0.0` 視為合法(是空操作)。
- `pm_plan_steps` 的驗證與 `plan` 呼叫全部寫在 `firewall pmErrInternal $` 之內,拆 `CDouble` newtype 而非 `realToFrac`。
- 場景版的「狀態不變」沒有 `pm_scene_age` 可讀,改以 `pm_scene_observe` 的六欄＋批次描述子**逐位元**比對(`castFloatToWord32`)。比對前先推進 40 幀並斷言存活粒子數 > 0——最初只推進 3 幀,ring-fire 當時一顆粒子都還沒生出來,「前後相同」變成恆真,合法步長那條反向斷言因此紅過一次(已修正並保留該防呆斷言)。
- T5 另外補了一條具體回歸測試:餵一幀 NaN 之後,照標頭寫法跑 `while (!pm_is_finished)`(帶 5000 幀上限),必須正常結束——這正是缺陷本身。

### 四、A5 的病態案例維持不修

`plan 1e-300 8 1e300 0 == StepPlan 0 1e300` 逐位元鏡射,不在 C 面補救(見待確認假設 A5)。若判定為缺陷,應在 boundary-host 開 bugfix 修 `Magic.Step.plan`,C 面自動跟著修正。
