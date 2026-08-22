---
id: F003
type: feature
title: spell-cost-model
description: 法力代價維度與可選上限的編譯閘門,粒子與法力超支可分辨
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: [adr-0011]
related-feature: []
---

# F003: 法術代價模型(法力維度與可選上限編譯入口)

## 功能概述

C1.3 預算護欄目前只有一個維度——粒子總量,對 `budgetCap` 逐一檢查,超限一律是 `BudgetExceeded`。本輪加第二個代價維度:**法力(mana)**,一個由符文組合結構(不含力場、發動點、陣的時間軸這些「陣層級屬性」)在編譯期算出的整數,可選擇性地與一個上限比較。

驗收標準(對齊契約卡):

1. 符文組合的法力代價可在編譯期由 `Circle` 結構算出(`manaCost`),不看粒子數、不看取樣結果。
2. 有一個帶上限的編譯入口:給了上限且超限,回傳新的 `CompileError` 建構子 `ManaExceeded`,與既有的 `BudgetExceeded`(粒子超支)不同建構子——宿主 `case` 得出來是哪一類。
3. 不給上限(`Nothing`)時,新入口與現行 `compile`/`compileMany` 逐位元一致——這是建構上成立的事,不是測出來的巧合。
4. 多張陣合成(`compileManyWithManaCap`)時,法力代價先加總所有circle的 `manaCost`,再對同一個上限檢查一次,呼應粒子預算「合成後checked once」的既有規則。
5. `CompileError` 新建構子依 ADR-0011 D7 的純增補律連動 C ABI:`include/particle_magic.h` 新增一個沒被用過的錯誤碼、`bindings/csharp/ParticleMagic.cs` 對應加一個常數、`test/FFIContractSpec.hs` 的兩張窮盡清單同步收錄——現有 31 個 C 匯出符號與既有錯誤碼值一個都不動。

## 相依性

（本節與 frontmatter 的 `depends-on` 由下方「使用到的既有串接介面」表反推，見文末一致性檢查。）

介面表裡引用的每一個型別與函式都來自**已交付的歷史程式碼**(`Magic.Compile`/`Magic.Rune`/`Magic.Circle`/`Magic.FFI`/`include/particle_magic.h`/`bindings/csharp/ParticleMagic.cs`,對應舊體系 func-spec 0002/0009/0011,詳見 [legacy-map.md](../../../legacy-map.md)),沒有任何進行中的 `.design/` 任務文檔提供這裡用到的介面——包含同子系統的 `F001`(sigil-time-axis,已 done):`F001` 動過 `Magic.Circle`/`Magic.Compile`/`Magic.Codec`,但本輪讀到的是它交付後的當前狀態(`circleSigil`/`sigilEnd` 等),不依賴它「進行中」的任何東西。因此 **`depends-on: []`**,可與任何其他子系統平行開發。

同一子系統內會動到的檔案(`src/core/Magic/Compile.hs`)目前沒有其他進行中的任務在碰,故無序列化衝突。

## 對應的 Level 2 契約

- **C1.3 預算護欄**:擴充為兩個代價維度(粒子、法力),各自對各自的上限檢查;粒子維度的既有語意（`budgetCap`、`BudgetExceeded`）完全不動。
- **C1.1 單張編譯**：既有簽名與語意不動（"不給上限時行為與現行一致" 由此構造性成立）；新增一個帶上限的編譯入口，不是修改 `compile` 本身。
- **C1.2 多張合成**：法力代價比照粒子預算的「相加後對同一上限檢查」規則。
- 不擴充 C2（編譯後的法術 DTO）：法力代價是編譯期的**閘門判斷**，不是法術跑起來要用的資料，`CompiledSpell` 的欄位一個都不加（見下方「明確不做」）。
- 不擴充 C3、C4：符文陣（M5）與空間查詢與本卡無關。

## 實作方式

### 1. 為什麼法力代價不進 `CompiledSpell`

契約卡的驗收標準只要求「可在編譯期算出並與上限比較」與「超限被拒絕、能分辨類別」——都是編譯期的判斷，不要求執行期查詢法力數字。`CompiledSpell` 是六件套 DTO（生命週期、粒子總量、預算計畫、發射器、界標、力場環境），法力代價不屬於取樣器、宿主查詢、或 GPU 緩衝配置需要的任何一項，加進去只是多一個沒人讀的欄位。維持 `CompiledSpell` 不動，也讓這一輪的漣漪只留在 `Magic.Compile` 的新函式與 `CompileError` 本身，不牽動這個型別的既有 40 處建構位置。

### 2. 法力代價的型別與單位

`Int`，unitless「法力點數」，與粒子數（`Int`）同一種算術，不另立 `newtype`——契約卡明講「不定義遊戲的數值平衡」，用 `Int` 而非某個度量單位的型別，是刻意不去暗示這個數字有物理意義。

### 3. 權重表的顆粒度：符文槽的建構子，不下鑽到符文的參數型別

「Magic.Rune 的每個建構子」查證後認定為**符文陣營自己的建構子**——`OuterRune`（4）、`BridgeRune`（3）、`InnerRune`（3）、`EssenceRune`（1，記錄型別視為單一建構子，依 `Element` 值域再分）、`NodeRune`（1）——而不是遞迴進每個建構子攜帶的子型別（`Trajectory` 8 變體、`FaceShape` 8 變體、`RadiationMode` 4 變體、`BillboardShape` 5 變體）。理由是既有的 fold（`applyInner`/`applyBridge`/`applyOuter`，`Magic.Compile.hs`）本身就只在這個顆粒度上 `case`——`motTraject`、`motSpawn` 這些欄位把 `Trajectory`/`FaceShape` 整個值當資料存起來，從不對它們的建構子分派邏輯。法力權重表照抄這個既有的顆粒度慣例，而不是發明一個更細的、fold 都不用的分類。

`ForceField`（5 建構子）與 `Anchor`（1）不計入：`Magic.Rune` 的模組註解自己說明它們是「circle-level property, not a rune」（`circleFields`/`circleAnchors`，ADR-0010 D4、func-spec 0025 §2.5），不是符文槽，契約卡的範圍是「符文組合」的代價，這兩個依語意就在範圍外。`circlePhases`/`circleSigil` 同理（陣的時間軸，不是符文）。

### 4. 權重表（Level 3 裁決，記在本文檔）

單一函式 `manaCost :: Circle -> Int`，內部對五個符文槽分別查一張常數表後相加；`Nothing`（空槽）一律貢獻 0——這是空陣法力代價為 0（不論上限多低都放得過）的構造性理由，呼應「空陣即素放」律。

| 符文類別 | 建構子 | 法力權重 | 理由 |
|---|---|---:|---|
| `OuterRune`（外圈，presentation） | `ShapeRune _` | 2 | 決定初始面形狀 |
| | `RadiateRune _` | 1 | 只是參考方向 |
| | `RangeRune _` | 3 | 掛一條玩家算式（動態曲線） |
| | `StyleRune _` | 1 | 純外觀 |
| `BridgeRune`（夾層，modulation） | `PhaseRune _` | 1 | 純時間位移 |
| | `ConvergeRune _` | 3 | 玩家算式 |
| | `AmplifyRune _` | 3 | 玩家算式 |
| `InnerRune`（內圈，behavior） | `TrajectoryRune _` | 2 | 內建軌跡 |
| | `TimingRune _` | 1 | 只換時序參數 |
| | `FormulaRune _` | 4 | 完整自訂 3D 算式，表達力最高 |
| `EssenceRune`（核心中心，essence） | 依 `essElement`：`Neutral` | 0 | 素放本身不額外計費 |
| | `Fire`／`Water`／`Metal`／`Wood`／`Earth` | 2 | 五行基礎 |
| | `Lightning`／`Yin`／`Yang` | 3 | 較晚加入、視覺與語意更強的三個元素 |
| `NodeRune`（核心節點，四方向） | `DirBias _` | 1（每個生效節點） | 每個方向偏置獨立計費 |

`essPower`（`EssenceRune` 的強度參數）**不計入法力**：它已經是既有粒子預算的輸入（`interpretCore` 用它換算 `count`），法力維度只看「用了哪些符文」，不重複對同一個旋鈕收兩次費——這也是「不重新定義粒子維度」的具體體現。

窮盡性：五個查表函式各自對其符文類型做 `case`，`Magic.Rune` 未來新增建構子時，GHC 的不完整樣式警告會指出所有待補位置（專案沒開 `-Werror`，但這是 `elementAppearance`/`evalInterval` 等既有函式的相同慣例，不新增依賴、不改變 CI 門檻）。

### 5. `compileWithManaCap` / `compileManyWithManaCap`：新入口而非 `Limits` 記錄

只加一個維度的上限（法力），粒子上限仍是全域常數 `budgetCap`——這一輪不打算讓粒子上限也可調（契約卡未提及，且會是另一個更大的決定）。用一個 `Limits` 記錄把「已經固定的粒子上限」和「本輪才有的、選配的法力上限」包在一起，會讓型別暗示兩者對等，其實不然。改用最小信號：`Maybe Int`——`Nothing` = 不檢查法力（現行行為），`Just cap` = 檢查。這與 `circlePhases`/`circleFields`/`circleAnchors`/`circleSigil` 一路「`Maybe`＝opt-in」的慣例一致。

```haskell
compileWithManaCap :: Maybe Int -> Circle -> Either CompileError CompiledSpell
compileManyWithManaCap :: Maybe Int -> [Circle] -> Either CompileError CompiledSpell
```

順序規則（兩個函式共用）：

1. 先跑既有的 `compile`/`compileMany`——粒子預算檢查照舊跑在最前面。若已經是 `Left (BudgetExceeded …)`，直接回傳，法力檢查完全不做：粒子超支優先於法力超支，一次編譯只回報一個錯誤，不會讓法力超支蓋過已經存在的粒子超支。
2. 只有粒子預算通過（`Right spell`）時才檢查法力：`mCap = Nothing` 直接回傳 `Right spell`（與 `compile`/`compileMany` 的既有回傳值逐位元相同——這正是驗收標準 3 構造性成立的原因）；`mCap = Just cap` 時，總法力（單張用 `manaCost circle`，合成用 `sum (map manaCost circles)`）超過 `cap` 才回 `Left (ManaExceeded total cap)`，否則回傳步驟 1 的 `Right spell` 不變。

`compileManyWithManaCap [] = compileWithManaCap` 對單元素串列的行為與 `compileMany`/`compile` 的既有恆等式（`compileMany [] == Right mempty`、`compileMany [c] == compile c`）完全相容，因為法力加總是在既有結果之上疊加的純函數，不改變 `compile`/`compileMany` 本身的任何既有恆等式。

### 6. `CompileError` 新建構子

```haskell
data CompileError
  = BudgetExceeded !Int !Int  -- 既有：requested particle count, cap
  | ManaExceeded !Int !Int    -- 新增：requested mana cost, cap
  deriving (Eq, Show)
```

只加在最後，不動 `BudgetExceeded` 的既有語意與位置——`CompileError` 本身不像 `Element`/`BillboardShape` 靠宣告順序當 wire code（它經 FFI 是靠一個顯式的分類函式，不是 `fromEnum`），所以附加順序沒有凍結序位的顧慮。

### 7. C ABI 純增補：新錯誤碼 `PM_ERR_MANA`

現有錯誤碼用到 `-7`（`PM_ERR_STATE`），下一個沒用過的值是 **`-8`**。

- `include/particle_magic.h`：`#define PM_ERR_MANA (-8)`，緊接 `PM_ERR_STATE` 之後的區塊，附註明：本輪任何既有入口（`pm_cast`/`pm_cast_ex`/`pm_scene_cast*`）都不會回傳它——因為它們呼叫的是不帶上限的 `compile`/`compileMany`；這個碼是為未來把 `compileWithManaCap` 接上 FFI 預留的，符合 ADR-0011 D7「新建構子先連動錯誤碼」的純增補律。
- `Magic.FFI`：新增 `pmErrMana :: CInt; pmErrMana = -8`，加入模組匯出清單，緊鄰其餘 `pmErr*`。
- `bindings/csharp/ParticleMagic.cs`：新增 `public const int ErrMana = -8;  // PM_ERR_MANA`，緊接 `ErrState` 之後。`test/BindingContractSpec.hs` 本身**不需要改動程式碼**——它已經是泛用解析器（掃描 `public const int … // MACRO` 這種格式並雙向比對），查證過全文件內容，新增的常數只要照這個註解慣例寫，就會被自動納入雙向比對，不必新增任何一條 `it`。
- `test/FFIContractSpec.hs`：兩處寫死清單要同步收錄 `"PM_ERR_MANA"`——(a)「agrees with Haskell on every error code」的 `expected` 對照表加一列 `("PM_ERR_MANA", pmErrMana)`；(b) 「declares the scene handle opaque…」測試裡那張完整 `#define` 名稱清單（目前 28 個，加了這個變 29 個）——這張是雙向 `sort ... shouldBe sort [...]`，漏加就會紅，不是可選項。
- **`refusalCode`（`Magic.FFI`）與 `pm_cast_ex` 的錯誤分類邏輯本輪不動**：它們目前把 `CompileFailed _` 一律映成 `pmErrBudget`（萬用字元，不對 `CompileError` 窮盡），編譯期不會因為新建構子而出錯；而且現有進入點都走不帶上限的 `compile`/`compileMany`，`ManaExceeded` 這條分支在這一輪透過 FFI 是不可達的死碼。把這條分類邏輯改到能分辨兩種錯誤碼，屬於「開新的 boundary/FFI 入口讓宿主給上限」那個更大的決定（見下方「明確不做」），留給那一輪一起做，避免這輪為一段測不到的程式碼背書。

### 8. `tools/Validate.hs` 與 `tools/Inspect.hs` 的窮盡分支

`renderCompileError`（`tools/Validate.hs`）與 `renderCompileErrorForInspect`（`tools/Inspect.hs`）都是對 `CompileError` 的**窮盡** `case`（兩處註解都寫明「Matched exhaustively on purpose」），新建構子必須補分支，否則往後任何人加 `-Wall` 警告都看得到不完整樣式。兩處文字一致（沿用既有 `BudgetExceeded` 分支的措辭風格）：

```haskell
ManaExceeded wanted cap ->
  "too much mana: this circle costs "
    ++ show wanted
    ++ ", the cap is "
    ++ show cap
```

這兩個函式目前的唯一呼叫路徑（`castSpell`／`inspectReport`）都走不帶上限的 `compile`，所以這個分支同樣是死碼——加它純粹是保住「新增建構子必須讓這裡的窮盡樣式繼續窮盡」這個既有約定，而不是給這一輪的任何驗收標準充數。

### 9. 明確不做

- **不重算/不重新定義粒子維度**：`budgetCap`、`BudgetExceeded`、`compile`、`compileMany` 的既有邏輯與簽名一個字不動。
- **不在執行期重算代價**：`manaCost` 只在編譯期呼叫；`CompiledSpell`/取樣器/`Magic.Interface`/`Magic.Scene` 都碰不到它。
- **不把上限寫進魔法陣的資料**：`Circle`（`Magic.Circle`）不增加任何欄位，`Magic.Codec` 不增加任何 JSON 鍵，`tools/Schema.hs` 與 `docs/spell.schema.json`／`docs/spell-schema.md` 都不用動。
- **不開 boundary/FFI 的入口讓宿主設定法力上限**——見下段理由，本輪只到核心（`Magic.Compile`）為止；`src/boundary/Magic/Interface.hs`、`src/boundary/Magic/Scene.hs`、`src/ffi/Magic/FFI.hs` 的**進入點清單與行為**都不變（新增的 `pmErrMana` 只是一個保留碼，不代表任何入口的行為改變）。
- **不定義遊戲的數值平衡**：上面的權重表是本卡為了讓驗收標準可測而給的具體數字，不是遊戲設計裁決；遊戲層要調整,直接改這張表的常數,不影響任何介面。
- **不修改 `CompiledSpell` 的欄位**（見「實作方式」1）。

### 10. 為什麼 boundary 與 FFI 這一輪不開新入口（回答委派指定的設計問題）

契約卡的驗收標準只要求「符文組合的法力代價可在編譯期算出並與上限比較」——這句話在核心層（`Magic.Compile`）就能完整驗證,不需要任何宿主可見的 API。反過來若要開一個宿主可用的入口,還有一整串沒被這輪的批次澄清定案的問題:法力上限要不要能對每個 `Circle`/每次施法個別設定(需要 `CastRequest` 或另一個參數)?要不要有場景層級的法力配額(`Magic.Scene` 的 `SceneConfig` 現在只管粒子的 `global_cap`)?FFI 的簽名要不要新增一個參數,還是靠一個新的 `_ex` 變體?這些都是「階段五、遊戲整合」量級的決定,契約卡的「明確不做」也寫了「不定義遊戲的數值平衡」——沒有遊戲層拍板要不要做成每個宿主可調、可持久化的設定之前,現在開一個入口只是先射一箭再畫靶。維持核心層閘門機制,讓未來需要它的 feature 再決定怎麼把它露出去,是這裡成本最低、可逆性最高的選擇。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data CompileError = BudgetExceeded !Int !Int deriving (Eq, Show)` | `src/core/Magic/Compile.hs` | - | 加第二個建構子 `ManaExceeded`（func-spec 0002 交付的既有型別） |
| `compile :: Circle -> Either CompileError CompiledSpell` | `src/core/Magic/Compile.hs` | - | `compileWithManaCap` 內部先呼叫它做既有的粒子預算檢查 |
| `compileMany :: [Circle] -> Either CompileError CompiledSpell` | `src/core/Magic/Compile.hs` | - | `compileManyWithManaCap` 內部先呼叫它 |
| `budgetCap :: Int` | `src/core/Magic/Compile.hs` | - | 對照組：粒子上限是全域常數，法力上限刻意不比照這個做法（見「實作方式」5） |
| `data Circle = Circle { outerRings :: TwoOf (Maybe OuterRune), interLayer :: Maybe BridgeRune, innerRings :: TwoOf (Maybe InnerRune), core :: Core, .. }` | `src/core/Magic/Circle.hs` | - | `manaCost` 走訪的五個符文槽 |
| `data Core = Core { coreCenter :: Maybe EssenceRune, coreNodes :: Nodes (Maybe NodeRune) }` | `src/core/Magic/Circle.hs` | - | 核心的中心符文與四方向節點符文 |
| `data TwoOf a = TwoOf { ringA :: a, ringB :: a }` | `src/core/Magic/Circle.hs` | - | 外圈／內圈各兩層的存取 |
| `data Nodes a = Nodes { north :: a, south :: a, east :: a, west :: a }` | `src/core/Magic/Circle.hs` | - | 四方向節點的存取 |
| `data OuterRune = ShapeRune FaceShape \| RadiateRune RadiationMode \| RangeRune Expr \| StyleRune BillboardShape` | `src/core/Magic/Rune.hs` | - | 外圈符文權重表窮盡覆蓋的值域 |
| `data BridgeRune = PhaseRune !Seconds \| ConvergeRune Expr \| AmplifyRune Expr` | `src/core/Magic/Rune.hs` | - | 夾層符文權重表窮盡覆蓋的值域 |
| `data InnerRune = TrajectoryRune Trajectory \| TimingRune Envelope \| FormulaRune ExprV3` | `src/core/Magic/Rune.hs` | - | 內圈符文權重表窮盡覆蓋的值域 |
| `data EssenceRune = EssenceRune { essElement :: !Element, essPower :: !Double }` | `src/core/Magic/Rune.hs` | - | 核心中心符文；權重依 `essElement`，`essPower` 不計入 |
| `data Element = Neutral \| Fire \| Water \| Lightning \| Metal \| Wood \| Earth \| Yin \| Yang deriving (Eq, Show, Enum, Bounded)` | `src/core/Magic/Rune.hs` | - | 元素權重表窮盡覆蓋的值域 |
| `newtype NodeRune = DirBias Double` | `src/core/Magic/Rune.hs` | - | 節點符文權重表窮盡覆蓋的值域（單建構子） |
| `interpretCore :: Core -> Either CompileError SpellSeed`（內部，未匯出） | `src/core/Magic/Compile.hs` | - | 對照組：既有的粒子計數已經消費 `essPower`，確認法力維度不重複收費的依據 |
| `refusalCode :: CastRefusal -> CInt` | `src/ffi/Magic/FFI.hs` | - | 查證現況：目前對 `CompileFailed _` 一律回 `pmErrBudget`（萬用字元），本輪確認不改（見「實作方式」7） |
| `pm_cast_ex :: CString -> ... -> IO CInt`（`Left err -> fail' pmErrBudget (...)`） | `src/ffi/Magic/FFI.hs` | - | 查證現況：同上，確認不改 |
| `pmErrJson, pmErrBudget, pmErrCapacity, pmErrArgs, pmErrQuota, pmErrInternal, pmErrState :: CInt`（值 -1..-7） | `src/ffi/Magic/FFI.hs` | - | 確認 `-8` 是下一個沒用過的值 |
| `#define PM_ERR_STATE (-7)`（其餘 `PM_ERR_*` 定義） | `include/particle_magic.h` | - | 同上，C 側的現況查證 |
| `public const int ErrState = -7;  // PM_ERR_STATE` | `bindings/csharp/ParticleMagic.cs` | - | `ErrMana` 的格式範本（`public const int Name = Value;  // MACRO`） |
| `headerFunctions, headerDefines, readUtf8`（`BindingContractSpec` 從 `FFIContractSpec` 匯入的泛用解析器） | `test/FFIContractSpec.hs` | - | 查證 `test/BindingContractSpec.hs` 是泛用雙向比對，本輪不需要改它的程式碼 |
| `renderCompileError :: CompileError -> String`（窮盡 `case`） | `tools/Validate.hs` | - | 需要補 `ManaExceeded` 分支 |
| `renderCompileErrorForInspect :: CompileError -> String`（窮盡 `case`） | `tools/Inspect.hs` | - | 需要補 `ManaExceeded` 分支 |
| `CompileError (..)`（再匯出，未窮盡使用） | `src/boundary/Magic/Interface.hs` | - | 查證：邊界層只再匯出型別與建構子，沒有對 `CompileError` 窮盡的 `case`，本輪不用改這個檔 |
| `data CastRefusal = CompileFailed !CompileError \| QuotaExceeded !Int !Int` | `src/boundary/Magic/Scene.hs` | - | 查證：只是把 `CompileError` 包一層，沒有窮盡的 `case`，本輪不用改這個檔 |

## 新增的介面

```haskell
-- src/core/Magic/Compile.hs（新增，加入匯出清單）

-- | 第二個編譯錯誤：法力超支（func-spec magic-semantics/F003）。與既有
-- 'BudgetExceeded'（粒子）並列，宿主可以 'case' 出是哪一類。ADR-0011 D7
-- 純增補律：只加不改，C ABI 對應新增 'PM_ERR_MANA'。
data CompileError
  = BudgetExceeded !Int !Int
  | ManaExceeded !Int !Int
  -- ^ Requested mana cost, cap.
  deriving (Eq, Show)

-- | 一張魔法陣的法力代價：五個符文槽（外圈兩層、夾層、內圈兩層、核心中心、
-- 四個核心節點）各自查一張常數權重表後相加；空槽貢獻 0。純函數，只看
-- 'Circle' 的符文組合結構，不看粒子數、不看 'essPower'（那已經是既有粒子
-- 預算的輸入，法力維度不重複收費）。
manaCost :: Circle -> Int

-- | 'compile' 加一個可選的法力上限。'Nothing' 與 'compile' 逐位元相同
-- （構造性零漣漪）。'Just cap' 時，粒子預算檢查優先——'compile' 本身的
-- 'BudgetExceeded' 蓋過法力檢查；只有粒子預算通過後，'manaCost' 超過
-- 'cap' 才回 'Left (ManaExceeded total cap)'。
compileWithManaCap :: Maybe Int -> Circle -> Either CompileError CompiledSpell

-- | 'compileMany' 的對應版本：合成後的法力總量（Σ 'manaCost'）先加總，
-- 再對同一個 'cap' 檢查一次——呼應粒子預算「相加後 checked once」的既有
-- 規則（'compileMany' 本身不變）。
compileManyWithManaCap :: Maybe Int -> [Circle] -> Either CompileError CompiledSpell

-- include/particle_magic.h（新增，只加不改，緊接 PM_ERR_STATE 之後）
-- #define PM_ERR_MANA (-8)
-- 本輪任何既有入口都不會回傳它：pm_cast/pm_cast_ex/pm_scene_cast* 都不
-- 接受法力上限參數，這個碼是給未來把 compileWithManaCap 接上 FFI 預留的。

-- src/ffi/Magic/FFI.hs（新增，加入匯出清單，緊鄰其餘 pmErr*）
pmErrMana :: CInt
-- pmErrMana = -8

-- bindings/csharp/ParticleMagic.cs（新增，緊接 ErrState 之後）
-- public const int ErrMana = -8;  // PM_ERR_MANA
```

## TodoList

- [ ] T1: `Magic.Compile` 新增 `ManaExceeded` 建構子與 `manaCost :: Circle -> Int`（內部五個窮盡權重查表，覆蓋 `OuterRune`/`BridgeRune`/`InnerRune`/`EssenceRune`/`NodeRune` 每個建構子），加入模組匯出清單  `dep: -`
- [ ] T2: `Magic.Compile` 新增 `compileWithManaCap`／`compileManyWithManaCap`：`Nothing` 與現行 `compile`/`compileMany` 逐位元一致；粒子預算優先於法力檢查；合成先加總 `manaCost` 再對同一上限檢查一次  `dep: T1`
- [ ] T3: C ABI 純增補：`include/particle_magic.h` 新增 `PM_ERR_MANA (-8)`；`Magic.FFI` 新增並匯出 `pmErrMana`；`bindings/csharp/ParticleMagic.cs` 新增 `ErrMana`；`test/FFIContractSpec.hs` 的「every error code」對照表與「完整 #define 清單」兩處同步收錄 `PM_ERR_MANA`  `dep: T1`
- [ ] T4: `tools/Validate.hs` 的 `renderCompileError` 與 `tools/Inspect.hs` 的 `renderCompileErrorForInspect` 補上 `ManaExceeded` 分支，恢復窮盡  `dep: T1`
- [ ] T5: 迴歸守護：`compileWithManaCap Nothing`／`compileManyWithManaCap Nothing` 與 `compile`／`compileMany` 在同一次執行內對出貨陣與隨機產生的陣（`SigilGen.genAnyCircle`）逐位元相同（`CompiledSpell` 的 `Eq` 比較），不重錄任何 golden  `dep: T2`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test/ManaWeightSpec.hs` | `manaCost emptyCircle == 0`；逐一驗證每張權重表（`OuterRune` 4 建構子、`BridgeRune` 3、`InnerRune` 3、`EssenceRune` 依 9 個 `Element`、`NodeRune`）與本文檔表格的常數相符；多符文同時出現時 `manaCost` 是各槽權重之和（含四個節點分別計費）；`essPower` 改變不影響 `manaCost`（只影響既有粒子數） |
| T2 | `test/ManaCapSpec.hs` | `compileWithManaCap Nothing c == compile c`（任取一個非平凡 circle）；`compileWithManaCap (Just cap) c` 在 `manaCost c <= cap` 時等於 `compile c`、超過時等於 `Left (ManaExceeded (manaCost c) cap)`；一個粒子已超但法力未超的 circle 用 `compileWithManaCap (Just 極大值)` 呼叫時回傳的仍是 `Left (BudgetExceeded ...)`（粒子優先於法力）；`compileManyWithManaCap (Just cap) [c1, c2]` 的判斷依據是 `manaCost c1 + manaCost c2`，而非兩者分別檢查 |
| T3 | `test/FFIContractSpec.hs`（既有檔擴充） | `pmErrMana \`shouldBe\` -8`；`lookup "PM_ERR_MANA" header == Just (-8)`；完整 `#define` 名稱清單（29 項）含 `"PM_ERR_MANA"`；`test/BindingContractSpec.hs`（既有、泛用、免修改）的三條既有 `it` 自動連帶驗證 `ParticleMagic.cs` 的 `ErrMana` 常數 |
| T4 | `test/ManaErrorRenderSpec.hs` | `renderCompileError (ManaExceeded 10 5)` 與 `renderCompileErrorForInspect (ManaExceeded 10 5)` 都含 `"mana"`、`"10"`、`"5"`，且與 `renderCompileError (BudgetExceeded 10 5)` 的字串不同（人類可分辨兩種超支） |
| T5 | `test/ManaCapZeroRippleSpec.hs` | 對 `assets/spells/` 全部出貨陣與 `SigilGen.genAnyCircle` 產生的隨機陣：`compileWithManaCap Nothing c === compile c`、`compileManyWithManaCap Nothing [c] === compileMany [c]`（`CompiledSpell` 的 `Eq`），不新增或修改任何 `test/golden/` 檔案 |

## 待確認假設

- A1：法力權重表的具體常數（本文檔「實作方式」4 的表格）是本卡在「不定義遊戲數值平衡」前提下為了讓驗收標準可測而給的具體數字，不是與開發者訪談確認過的遊戲設計值 → 採取：以「四類符文既有的 fold 顆粒度」為準，給出結構合理、彼此有區分度的小整數表，並在文檔中明文記錄理由（含 `essPower` 不重複收費、力場/發動點/陣時間軸不計入的排除理由）→ 影響：若遊戲層日後要調整平衡，只需改 `manaCost` 內部常數表，不影響任何簽名或介面，`test/ManaWeightSpec.hs` 需要跟著改期望值。
- A2：`refusalCode`／`pm_cast_ex` 的錯誤碼分類邏輯本輪維持「`CompileFailed _` 一律 `pmErrBudget`」不變，只在核心層與 tools 層的窮盡 `case` 分辨兩類錯誤 → 採取：因為本輪不開 boundary/FFI 入口讓宿主設定法力上限，現有入口確實永遠不會產生 `ManaExceeded`，改動這段分類邏輯沒有可測的觀察點 → 影響：未來若要把 `compileWithManaCap` 接上 FFI（開新入口），那一輪需要同時把 `refusalCode`／`pm_cast_ex`（以及對應的 `Magic.Scene.admit`／`CastRefusal` 路徑，如果走場景）改成依 `CompileError` 建構子分派到 `pmErrBudget`／`pmErrMana`，並補上那條路徑的 FFI 測試。

## 實作備註

（實作期間與規格的偏差記錄於此，撰寫時留空。）
