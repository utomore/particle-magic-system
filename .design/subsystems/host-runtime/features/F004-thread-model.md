---
id: F004
type: feature
title: thread-model
description: 同控制代碼原子推進不丟更新，執行緒模型明文化
status: done
created: 2026-08-20
updated: 2026-08-21
depends-on: [F002]
related-adr: [ADR-022]
related-feature: []
---

# F004: 執行緒模型

## 功能概述

**要解決的問題**：`src/ffi/Magic/FFI.hs` 今天對「兩個執行緒同時碰同一個控制代碼」沒有任何保護，而且文件把這件事說成「不支援」而不是「會怎樣」。

- `pm_advance`（:436-439）是一個**非原子的 read-modify-write**：`readIORef` 取出 `ActiveSpell`、算出下一步、`writeIORef` 寫回。兩個執行緒交錯執行時，後寫的那一個會蓋掉前一個的結果——法術靜默少推進一步。同一形狀還出現在 `pm_scene_advance`（:864-867）、`pm_scene_dismiss`（:854-857）與 `admitInto`（:836-843，兩個場景施法符號共用）。
- 標頭把承諾寫成「一個 handle 屬於一個執行緒」（`include/particle_magic.h:72-73`，場景版在 :60），`docs/integration.md:448` 與 :712 照抄。這句話對宿主毫無用處：它沒說「不同 handle 可不可以」，也沒說違反了會發生什麼。
- **零併發測試**：`test/FFI*Spec.hs` 六個模組沒有一行 `forkIO`（全專案只有 `ParallelSampleSpec` 動過 capability 數，而它測的是純取樣，不是控制代碼）。

[ADR-022](../../../adr/ADR-022-host-runtime-contract.md) D4 把這一層變成明文契約，[design.md](../design.md) C2.2 是它的子系統面。本功能把 C2.2 的四條承諾各自落成程式碼與測試。

**驗收標準**（契約卡原文）：

1. 不同控制代碼跨執行緒併發的測試穩定綠；
2. 同一控制代碼的 N 次併發推進後年齡恰為 N 步；
3. 標頭與整合指南明文列出可併發與必須序列化的操作；
4. 單執行緒 bench 的每次呼叫成本不因本項上升（壁鐘對照）。

第 4 條無法在奈秒解析度上字面成立——原子 RMW 有可量測的固定成本（實測 +6.5 ns／呼叫，見「5. 成本」）。本文件把它讀作「宿主每幀付的成本不上升」，並提出可機械檢查的替代門檻，記在 **A1**。

**明確不做**（契約卡）：不保證同控制代碼操作的**順序**；不做無鎖化改寫；不改變任何既有符號簽名；不開任何 OS 執行緒。

補充的不做（本文件裁定）：

- **不碰 `pm_init`／`pm_shutdown` 的併發**。初始化與關閉的原子化是 [F003](F003-rts-config-init.md) 的狀態機（C2.2 第三條、ADR-022 D1）；本功能的測試不呼叫 `pm_shutdown`（在測試進程裡它是單向門）。
- **不替宿主同步輸出緩衝**。兩個執行緒把同一個控制代碼觀測進**同一組**宿主陣列是宿主的資料競爭，庫看不見也管不著；這一條寫進標頭的「必須自行序列化」清單。
- **不改變任何取樣或推進的數值語意**。合法輸入的輸出逐位元不變是本功能的回歸網，不是目標。

## 相依性

`depends-on: [F002]`——**單一相依，且是文檔相依而非程式碼相依**。

介面表反推的候選集合是 `{F002}`：表中六列（`newSpellHandle`／`newSceneHandle`／`freeSpellHandle`／`freeSceneHandle`／`spellRegistryStats`／`sceneRegistryStats`）的來源是 `.design/subsystems/host-runtime/features/F002-handle-generation.md`「新增的介面」章節，**不是**今天的原始碼——F002 的世代標籤註冊表尚未實作。依查證規則，這六列相依的是**文檔的介面約定**，並在此註明。其餘每一列都從 `src/ffi/Magic/FFI.hs`、`src/boundary/Magic/*.hs`、`test/FFIHarness.hs`、`test/FFIContractSpec.hs`、`particle-magic.cabal`、`bench/Bench.hs` 或 `base` 讀出原文簽名，來源文檔為 `-`。

為什麼是 F002 而不是別的：本功能要動的兩處，一處（cell 的原子 RMW）與 F002 無關，另一處（**註冊表的配置與釋放要能跨執行緒**）直接建立在 F002 的註冊表上——F002 之前控制代碼是 `newStablePtr`／`freeStablePtr`（GHC 執行期自己同步的 stable pointer table），F002 之後變成庫自己管的 slot 陣列，於是「兩個執行緒同時施法」從 RTS 的問題變成本功能的問題。F002「6. 給 F004 留的接縫」已經預留了這個介面：**法術狀態仍住在 slot 內的 `IORef ActiveSpell`（不在註冊表裡）**，所以推進只需換 `readIORef`／`writeIORef`；**解析路徑唯讀**，所以不必上鎖；**註冊表變動集中在配置／釋放兩個函數**，所以同步原語只換那兩處，22 個呼叫端一行不動。本文件完全沿用這三條。

**能否平行開發**：與 F001、F003、F005、F006、F007、F008 皆可平行**設計**；實作依閘門裁決屬第二波，合併時 F002／F001／F003／F005／F007 可能都已落地。逐一的接縫：

| 平行／前置項目 | 關係 |
|---|---|
| **F002 handle-generation** | **前置**。註冊表的形狀與三條接縫直接沿用；本功能只在 F002 的配置／釋放兩個函數外面加一把寫入鎖，解析路徑不動 |
| **F001 exception-firewall** | 巢狀關係明確：`firewall`／`firewallErr` 包在每個匯出符號的**最外層**，本功能的原子步在**本體內**。唯一的實質互動是失敗語意——原子步失敗會毒化該控制代碼的 cell，於是之後每一次呼叫都由防火牆回 `PM_ERR_INTERNAL`（見「6. 原子步的失敗語意」）。本功能不引用 `pmErrInternal`，因此**不構成 `depends-on`** |
| **F003 rts-config-init** | 檔案交集只在 `src/ffi/Magic/FFI.hs` 的 29 行 `foreign export`：F003 把它們改成具名外部符號 `pm_hs_*`，**Haskell 函式名、簽名、本體不動**，而本功能改的正是本體，兩者不撞。C2.2 的「初始化與關閉原子化」整條由 F003 負責，本功能不重複；本功能的測試不呼叫 `pm_shutdown` |
| **F005 step-planner-c-abi** | F005 新增的 `pm_advance_ex`／`pm_scene_advance_ex` 是既有推進的錯誤碼變體，**必須走同一個原子步**；本功能提供的組合子就是那個掛點。`pm_plan_steps` 是純函數、無狀態、天然併發安全（標頭的可併發清單要列它） |
| **F006 oop-load-smoke** | 不同進程、不同層。本功能的併發測試是 in-process 的 hspec；F006 的純 C 宿主若要順便驗執行緒模型是加分項，不是本功能的出口 |
| **F008 host-doc-corrections** | **同檔不同段**：F008 改 `docs/integration.md` 的粒子上限敘述與範例主迴圈，本功能改 §4.4 的執行緒條目與 §8 限制表的「單執行緒 handle」列。合併時只有段落順序會撞 |

## 對應的 Level 2 契約

逐條對照 [design.md](../design.md)，確認未超出範圍：

| Level 2 條目 | 本功能做的事 | 是否超出 |
|---|---|---|
| **C2.2 執行緒模型** | 全部實作，除了「初始化與關閉原子化」：不同控制代碼可併發（含併發施法與釋放）、同一控制代碼不丟更新、不保證順序、單執行緒宿主無鎖 | 否 |
| **C2.2 的「初始化與關閉原子化」** | **不實作**（F003 的狀態機） | 否（明確不做） |
| **I2（M2 → M3）** | 沿用，不擴充：控制代碼仍一律經註冊表解析（F002 的半邊）、仍一律在防火牆內執行（F001 的半邊）。本功能加的是 M3 內部的同步原語，不是新的模組間介面 | 否 |
| **資料流管線「全段的併發語意」** | 逐段標註：驗證段（解析）唯讀無鎖、業務處理段的四個寫入點原子化、輸出段唯讀無鎖 | 否 |
| **C1「只加不改」** | 標頭**零新增**：無新符號、無新常數、無新結構、`PM_ABI_VERSION` 維持 1、`.def` 不動。只改寫兩段已作廢的執行緒散文 | 否 |
| **C1.1 生命週期** | 符號簽名與語意全部不變；改變的只有「同一控制代碼併發時會發生什麼」，而那件事今天是未定義的 | 否 |
| **對外承諾「C 面不多知道一件事」** | 併發語意不是新的模擬語意——邊界層的 `advanceSpell`／`advanceScene`／`castInto`／`dismiss` 都是純函數，本功能只決定**怎麼把純函數的結果寫回 cell** | 否 |
| **明文不做「每控制代碼互斥鎖序列化一切操作」** | 遵守：per-frame 路徑（推進／觀測／查詢）**一把鎖都沒有**。唯一的鎖在註冊表的配置／釋放——那是**表級**寫入鎖，不是控制代碼級的操作鎖，也不序列化任何 per-frame 操作 | 否 |

## 實作方式

### 1. 三種併發面，三種對策

`src/ffi/Magic/FFI.hs` 裡跨執行緒可見的可變狀態只有兩種：**每個控制代碼一個 cell**（`SpellCell (IORef ActiveSpell)` :290、`SceneCell (IORef Scene)` :317），以及 **F002 的兩張註冊表**。把 31 個符號按它們怎麼碰這兩種狀態分類，只剩四類：

| 類別 | 符號 | 今天 | 本功能 |
|---|---|---|---|
| **A 唯讀 cell** | `pm_is_finished`（:446）、`pm_age`（:455）、`pm_observe`／`pm_observe_ex`（:583）、`pm_spell_bounds`（:985）、`pm_spell_box`（:1009）、`pm_emitter_count`（:1018）、`pm_emitter_box`（:1035）、`pm_occupancy`（:1078）、`pm_occupancy_mask`（:1090）、`pm_scene_observe`（:905）、`pm_scene_budget`（:934）、`pm_scene_count`（:944）、`pm_scene_spells`（:954）、`pm_scene_spell_bounds`（:1108） | 一次 `readIORef` | **不動**。`readIORef` 取到的是一個不可變的 `ActiveSpell`／`Scene` 值，天生是快照：與併發的推進交錯時只會看到「推進前」或「推進後」，永遠不會看到半新半舊。這正是 C2.2「不保證順序」的可接受形式 |
| **B 讀改寫 cell** | `pm_advance`（:436-439）、`pm_scene_advance`（:864-867）、`pm_scene_dismiss`（:854-857）、`admitInto`（:836-843，`pm_scene_cast` 與 `pm_scene_cast_many` 共用） | `readIORef` ＋ `writeIORef $!` | **改為單一原子步**（§2） |
| **C 改註冊表** | `pm_cast_ex`（:425 的配置）、`pm_scene_new`（:691）、`pm_free`（:666）、`pm_scene_free`（:697）——F002 之後全部收斂成四個註冊表函數 | F002 之後是無保護的 slot 陣列讀寫 | **加一把表級寫入鎖**（§4） |
| **D 無狀態** | `pm_abi_version`、`pm_max_particles`、`pm_project`、`pm_depth_order`（以及 F005 的 `pm_plan_steps`） | 純函數 | **不動**，天然可併發 |

沒有第五類：全模組 `readIORef`／`writeIORef`／`newIORef` 的出現位置（`grep` 共 19 處）全部落在 A、B、C 之中。

### 2. 原子步：`atomicModifyIORef'`

B 類的四個站點改走同一個組合子。ADR-022 D4 指名的「原子的 read-modify-write」，在依賴白名單（`base`／`magic-boundary`／`bytestring`／`vector`，`particle-magic.cabal:242-245`，由 `test/FFIContractSpec.hs:237-242` 斷言）之內只有一個候選：`base` 的 `atomicModifyIORef' :: IORef a -> (a -> (a, b)) -> IO b`。**`stm` 與 `atomic-primops` 都在白名單外，不得引入。**

本文件對它做了四項實測查證（GHC 9.14.1、Windows x86_64、`-O2 -threaded`；程式與完整輸出在實作階段記進「實作備註」的 E1–E4）：

- **E1 不丟更新**：8 個 `forkOn` 執行緒各做 20000 次遞增，`readIORef` ＋ `writeIORef $!` 版本最終得到 **33060／160000**（丟掉約 80%），`atomicModifyIORef'` 版本得到 **160000／160000**。驗收標準第 2 條因此成立，這個對照同時是「測試有牙齒」的證據（§7）。
- **E2 強制到 WHNF**：`atomicModifyIORef'` 在回傳前把新值強制到 WHNF（以 `error` 觀測會拋出）。`ActiveSpell` 的四個欄位**全部是嚴格欄位**（`src/boundary/Magic/Interface.hs:163-171`），所以 WHNF 就已經強制了 `asElapsed` 與 `asField`——與今天 `writeIORef $!` 的強制深度**完全相同**，惰性不會在時鐘上堆 thunk。（實測：嚴格欄位裡的 `error` 會被 WHNF 觸發，惰性欄位不會；`Scene` 的寫回同理。）
- **E3 純函數只被求值一次**：`atomicModifyMutVar2#` 在 CAS 失敗時重試的是**指標交換**，落敗那次建立的 thunk 未被強制就丟棄。實測 8×20000 次併發更新中，被計數的純函數強制次數恰為 **160000**，與成功更新數相等。因此 `admitInto` 把 `castInto`／`castManyInto`（含編譯）放進原子步**不會在競爭下重複編譯**。
- **E4 成本**：見 §5。

組合子（`Magic.FFI` 的 Internals 區，比照 `writeErr` 匯出給測試）：

```text
stepCellWith :: IORef a -> (a -> (a, b)) -> IO b   -- 原子讀改寫，順帶回報一個結果
stepCell     :: IORef a -> (a -> a) -> IO ()       -- 前者在 b ~ () 的特例
```

兩者都只是 `atomicModifyIORef'` 的薄殼；它們存在的理由是**可稽核**（一個名字，`grep` 得到，測試釘得住）與**單一掛點**（F005 的兩個 `*_ex` 變體接同一個）。其餘實作細節（是否 `INLINE`、要不要再拆）留給實作階段。

四個站點的改法：

- `pm_advance`：`withCell h () $ \ref -> stepCell ref (advanceSpell (FrameInput (DeltaTime (cfloatToDouble dt))))`。
- `pm_scene_advance`、`pm_scene_dismiss`：同形狀，換成 `advanceScene (FrameInput …)` 與 `dismiss (SpellId …)`。
- `admitInto`：純決策進原子步、IO 留在外面——

```text
outcome <- stepCellWith ref $ \scene -> case admit scene of
             Left  refusal       -> (scene,  Left refusal)      -- 拒收：寫回原值
             Right (sid, scene') -> (scene', Right sid)
case outcome of
  Left refusal        -> castFail errBuf errLen (refusalCode refusal) (refusalMessage refusal)
  Right (SpellId sid) -> poke outId (fromIntegral sid) >> pure pmOk
```

拒收分支寫回**同一個值**，語意與今天「不寫回」相同（`Scene` 是不可變值），但保持成一次原子交換，於是併發的兩次施法一定各自看到對方的結果——配額不會被重複計入。`withCast`（:818）對 `outId` 的預設 `-1`、NULL 檢查與檢查順序**全部不動**。`pm_scene_cast_many` 的 `loadCircles`（:792-802，解 JSON）留在原子步**外面**：它是 IO，而且與場景狀態無關。

### 3. 「不保證順序」具體是什麼

C2.2 只承諾不丟更新。本功能要把「不保證順序」的可觀測後果寫清楚，因為那是宿主唯一需要防的東西：

- 兩次併發推進之後，年齡一定是兩步（不丟更新），但**哪一步先算**不保證——由於每一步都是「在前一個值上加同一個 `dt`」，最終狀態與交錯順序無關，所以這一條在推進上其實沒有可觀測差異（測試也因此可以做逐位元比對，見 §7）。
- 推進與觀測併發時，觀測看到的是**推進前或推進後的完整快照**，由 A 類的單次 `readIORef` 保證。宿主若要「這一幀的畫面必須對應這一幀的推進」，必須自己排這兩個呼叫的順序。
- 施法與解散併發時，`SpellId` 的配發順序不保證；`dismiss` 一個尚未被同一個場景接納的 id 是無操作（`Magic.Scene.dismiss` 的既有語意，`src/ffi/Magic/FFI.hs:850-852` 的註解）。
- **釋放與任何其他呼叫併發是宿主錯誤**：`pm_free` 之後控制代碼即失效，此時併發的另一個呼叫可能落在解析成功那一側、也可能落在世代不符那一側（F002 的 `PM_ERR_ARGS`）。兩種結果都不崩潰，但哪一種發生不保證。這條進標頭的「必須自行序列化」清單。

### 4. 註冊表的寫入鎖

F002 的註冊表是「頂層 `IORef Registry` ＋ 可變 slot 陣列」，配置與釋放要做 `MV.read`／`MV.write`／`MV.grow` 這些 IO，塞不進 `atomicModifyIORef'` 的純函數裡。做法是把**變動**串起來，**解析**維持原樣：

- 新增頂層 `MVar ()` 寫入鎖（`unsafePerformIO` ＋ `NOINLINE`，與 F002 的頂層註冊表同一個手法），法術與場景**各一把**（兩張表互不相干，分開才不會互相擋）。
- F002 的四個生命週期函數（`newSpellHandle`／`freeSpellHandle`／`newSceneHandle`／`freeSceneHandle`）整段包在 `withMVar` 內。`withMVar` 自帶 `mask`／`onException`，例外不會把鎖留在被持有的狀態。
- **解析路徑一個字都不改**：`withCell`／`withScene` 仍然是一次 `readIORef` ＋ 一次 `MV.read` ＋ 一次比較，**不取鎖**。這是「單執行緒宿主零額外成本」與「per-frame 路徑無鎖」的來源，也是為什麼不能照 F002 接縫的字面建議把頂層 `IORef` 換成 `MVar`（那會讓每一次解析都變成一次 take／put，見 A3）。

兩個必須寫進文件的後果：

- **跨執行緒交遞控制代碼要靠宿主自己的同步**。解析讀的是普通 `IORef`，沒有記憶體屏障；A 執行緒施法、B 執行緒使用，其間必須有宿主自己的同步（佇列、鎖、job system 的相依邊）——任何真的同步原語都會帶屏障。這與任何 C API 的規矩相同，但因為 macOS arm64 是 Tier 1 平台（弱記憶體模型），值得明說。
- **`MV.grow` 之後的短暫舊視圖**：一個在成長前讀到註冊表的解析者看到的是舊陣列。舊陣列的內容對成長前就存在的 slot 仍然正確；看不到的只有成長後新配發的控制代碼——而那個控制代碼要能被這個執行緒拿到，前提就是上一條的宿主同步。

這把鎖不是 design.md 明文不做的「每控制代碼互斥鎖序列化一切操作」：它是**表級**的、只在施法與釋放時取，per-frame 的推進與觀測完全碰不到它。

### 5. 成本

實測（GHC 9.14.1、`-O2 -threaded`、3×10⁶ 次呼叫、暖機後、Windows x86_64）：

| 形狀 | `-N1` | `-N8` | 每次呼叫配置 |
|---|---|---|---|
| `readIORef` ＋ `writeIORef $!`（今天） | 2.84 ns | 2.84 ns | 24 B |
| `atomicModifyIORef'`（本功能） | 9.31 ns | 11.15 ns | 104 B |
| `modifyMVar_`（落選的替代） | 9.87 ns | 17.37 ns | 96 B |

差額約 **+6.5 ns 與 +80 B／次推進**。放進尺度看：

- `cabal bench` 實測 `advanceSpell (60 fixed steps)`：ring-fire（無力場）**111 ns／60 步 ≈ 1.85 ns／步**，gravity-well（2 個力場）**2.22 ms／60 步 ≈ 37 µs／步**。
- 同一次 bench 的取樣成本：1024 粒 82 µs、16384 粒 1196 µs。
- 因此對無力場法術，`pm_advance` 這一支微基準會從約 5 ns 變成約 12 ns（**相對值大**）；對宿主而言，一幀一次推進的絕對增量是 6.5 ns，佔 60 fps 幀預算（16.67 ms）的 **4×10⁻⁵ %**，佔一次最小觀測（82 µs）的 0.008%。
- 純核心的取樣與推進路徑（`sample`、`advanceSpell` 兩個 bgroup）**一個位元都不改**，既有的 bench 數字不應移動。

`modifyMVar_` 在單執行緒下已略慢，在 `-N8` 下慢 56%，而且會阻塞——落選。`atomicModifyIORef'` 正是 ADR-022 D4「無鎖路徑，原子 RMW 在無競爭時成本可忽略」所指的東西。

**壁鐘對照怎麼留下來**：在 `bench/Bench.hs` 新增一個 bgroup，對同一個真實 `ActiveSpell` 各跑一次「舊形狀」與 `stepCell` 形狀。這個對照組**不需要動 `particle-magic.cabal`**——`Data.IORef` 在 `base`、`advanceSpell` 在已相依的 `magic-boundary`，而 bench stanza 沒有任何守門測試在管（`test/BoundarySpec.hs` 完全不提 bench）。實作階段把前後數字記進「實作備註」。

### 6. 原子步的失敗語意

`atomicModifyIORef'` 與 `writeIORef $!` 有一個**行為差異**，實測確認：新值是先原子安裝、再強制的，所以強制時拋出例外會讓 cell 留著一個**會拋的 thunk**——該控制代碼從此永久失效，之後每一次讀它都會再拋一次。今天的 `writeIORef $!` 是先強制再寫，例外之後 cell 保留舊值。

裁定：**接受這個差異並寫進文件與測試**，理由三條：

1. 能拋的來源在這裡幾乎不存在——`advanceSpell`／`advanceScene`／`dismiss`／`castInto` 是純的全函數（ADR-0007：核心不失敗，不合法組合在型別層不可表示），現實中的來源只剩堆積耗盡與非同步例外，而 ADR-022 D2 已經把「防火牆真的攔到東西」定義為缺陷。
2. 後果是**收斂而非擴散**：壞掉的只有那一個控制代碼，其他控制代碼與整個進程完全不受影響——這正是 P-1 要的形狀。與 F001 合併後，該控制代碼之後的每一次呼叫都由防火牆回 `PM_ERR_INTERNAL`，宿主看到的是持續、明確的錯誤碼，而不是從一個舊狀態靜靜繼續跑。
3. 要避免它就得在原子安裝前先強制一次（等於做兩遍功），或自己用 `casMutVar#` 寫 CAS 迴圈（`atomic-primops` 這個套件存在的理由就是裸 primop 有 ticket 語意的坑，而它在白名單外）。兩條都比問題本身糟。

### 7. 測試怎麼做到「可重複、不靠 sleep、不偽陰性」

併發測試最容易變成「跑一百次都綠，因為競爭根本沒發生」。四道防線：

1. **機械守門（完全確定性）**：一條原始碼稽核測試斷言 `src/ffi/Magic/FFI.hs` 裡**不再出現 `writeIORef`**——B 類四個站點全部經 `stepCell`／`stepCellWith`。有人把機制改回去，這一條**必紅**，與排程器無關。這是主要防線，其餘三條是輔助。
2. **牙齒檢查**：同一組執行緒骨架同時跑一份**故意非原子的孿生體**（測試模組自己定義的 `readIORef` → `yield` → `writeIORef`）。孿生體必須至少丟掉一次更新，測試才承認這台機器能重現競爭；若孿生體一次都沒丟，該條以 `pendingWith` 收場而**不是靜默通過**（priming → pending 的手法沿用 `test/PerfGoldenSpec.hs`）。這樣綠色永遠代表「牙齒驗過」或「明確標記為 pending」，不會偽陰性地說「通過」。
3. **確定性的斷言**：斷言本身沒有任何時間量。因為每一步都是「前一個值 ＋ 同一個 `dt`」，N 次併發推進的最終狀態與交錯順序無關，等於 N 次循序推進的結果——所以可以直接和 `FFIHarness.referenceStates` 的第 N 個狀態做**逐位元**比對（`Float` 比位元樣式），而不是比一個容差。年齡同理：`pm_age` 對照同一串 `dt` 的循序摺疊值。
4. **可重複的競爭形狀**：執行緒數與迭代數是寫死的常數；執行緒以 `forkOn i` 釘到不同 capability（不受排程器負載平衡影響）；全部先卡在一個起跑柵欄（一個空的 `MVar`，主執行緒填值後全體同時出發），結束以計數 `MVar` 收攏。**全程沒有 `threadDelay`**。capability 數以 `setNumCapabilities (max 2 (min 8 processors))` 暫時提高、測完還原，手法沿用 `test/ParallelSampleSpec.hs:186-199`。

### 8. 標頭與文件

**標頭零符號變更**（無新符號、無新常數、無新結構、`PM_ABI_VERSION` 維持 1、`.def` 不動）。改寫的是兩段已作廢的散文：

- `include/particle_magic.h:60`「Threading is per handle here too: one scene is owned by one thread.」
- `include/particle_magic.h:72-73`「Threading: one handle is owned by one thread. The library itself takes no locks (ADR-0011 D4); different handles on different threads are fine.」

換成一段完整的執行緒模型，內容為兩張清單：

| 可併發（庫負責） | 說明 |
|---|---|
| 不同控制代碼的任何操作 | 無限制 |
| 同一控制代碼的多次推進 | 不丟更新；N 次併發推進恰好推進 N 步 |
| 同一場景的多次施法／解散 | 不丟更新；配額不會被重複計入 |
| 推進與觀測（或任何查詢）併發 | 查詢看到的是推進前或推進後的完整快照，永不半新半舊 |
| `pm_abi_version`／`pm_max_particles`／`pm_project`／`pm_depth_order`（以及 F005 的 `pm_plan_steps`） | 無狀態，任何時候任何執行緒 |

| 必須由宿主自行序列化 | 為什麼 |
|---|---|
| `pm_free`／`pm_scene_free` 與同一控制代碼的任何其他呼叫 | 釋放後控制代碼即失效；併發者可能落在任一側（兩側都不崩潰，但結果不保證） |
| `pm_init`／`pm_init_ex`／`pm_shutdown` 與任何呼叫 | 執行期生命週期（F003） |
| 兩次寫進**同一組宿主陣列**的觀測 | 那是宿主自己的記憶體，庫看不見 |
| 把控制代碼交給另一個執行緒 | 需要宿主自己的同步（與任何 C API 相同） |
| 需要「畫面對應這一幀」的推進／觀測配對 | 庫不保證兩個呼叫的相對順序 |

另加三句：庫**不會自行開任何 OS 執行緒**；per-frame 路徑（推進、觀測、查詢）**不取任何鎖**；內部失敗只會讓**該一個控制代碼**永久回報內部錯誤，其他控制代碼與宿主進程不受影響。

守門用的哨兵詞（手法同既有的 `right-handed`／`0xRRGGBBAA`，`test/FFIContractSpec.hs:204-207`）：標頭必須含 **`no lost updates`** 與 **`never starts an OS thread`**，且不得再含 `one handle is owned by one thread`。

`docs/integration.md` 同步三處：§4.4 生命週期規則的第二點（:448）改寫為指向新的執行緒模型小節；§8 限制表的「單執行緒 handle｜庫內無鎖」列（:712）改寫為「同 handle 不保證順序」；新增一個小節放上面兩張清單的中文版，含哨兵詞 **`不丟更新`**。`bindings/csharp/ParticleMagic.cs:142` 的「one scene per thread」註解一併更正（只是註解，不影響 `test/BindingContractSpec.hs` 的進入點與常數對帳）。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `pm_advance :: StablePtr SpellCell -> CFloat -> IO ()` | `src/ffi/Magic/FFI.hs:435`（本體 :436-439） | - | B 類站點一：`readIORef`／`writeIORef` 換成原子步；簽名不動 |
| `pm_scene_advance :: StablePtr SceneCell -> CFloat -> IO ()` | `src/ffi/Magic/FFI.hs:863`（本體 :864-867） | - | B 類站點二 |
| `pm_scene_dismiss :: StablePtr SceneCell -> CInt -> IO ()` | `src/ffi/Magic/FFI.hs:853`（本體 :854-857） | - | B 類站點三 |
| `admitInto :: IORef Scene -> Ptr CInt -> CString -> CInt -> (Scene -> Either CastRefusal (SpellId, Scene)) -> IO CInt` | `src/ffi/Magic/FFI.hs:829-843` | - | B 類站點四；純決策進原子步、`poke`／`castFail` 留在外面 |
| `withCast :: StablePtr SceneCell -> Ptr CFloat -> Ptr CFloat -> Word64 -> CString -> CInt -> Ptr CInt -> (IORef Scene -> CastContext -> IO CInt) -> IO CInt` | `src/ffi/Magic/FFI.hs:808-818` | - | `admitInto` 的呼叫者；NULL 檢查、`poke outId (-1)` 與檢查順序全部不動 |
| `withCell :: StablePtr SpellCell -> b -> (IORef ActiveSpell -> IO b) -> IO b` | `src/ffi/Magic/FFI.hs:302` | - | 解析路徑；本功能**不改它**，只確認它唯讀、無鎖 |
| `withScene :: StablePtr SceneCell -> b -> (IORef Scene -> IO b) -> IO b` | `src/ffi/Magic/FFI.hs:327` | - | 同上（場景側） |
| `newtype SpellCell = SpellCell (IORef ActiveSpell)`、`newtype SceneCell = SceneCell (IORef Scene)` | `src/ffi/Magic/FFI.hs:290, 317` | - | 原子步作用的對象；型別與構造子不變 |
| `castFail :: CString -> CInt -> CInt -> String -> IO CInt` | `src/ffi/Magic/FFI.hs:845` | - | `admitInto` 拒收分支的既有形狀，移到原子步之後 |
| `refusalCode :: CastRefusal -> CInt`、`refusalMessage :: CastRefusal -> String` | `src/ffi/Magic/FFI.hs:226, 236` | - | 同上；分類與訊息不變 |
| `pm_cast_ex :: CString -> Ptr CFloat -> Ptr CFloat -> Word64 -> CString -> CInt -> Ptr (StablePtr SpellCell) -> IO CInt` | `src/ffi/Magic/FFI.hs:400-410` | - | 併發施法測試的入口；本功能只改它內部呼叫的註冊表配置的同步 |
| `pm_scene_new :: CInt -> IO (StablePtr SceneCell)`、`pm_scene_cast :: StablePtr SceneCell -> CString -> Ptr CFloat -> Ptr CFloat -> Word64 -> CString -> CInt -> Ptr CInt -> IO CInt` | `src/ffi/Magic/FFI.hs:689, 718` | - | 場景併發測試的入口 |
| `pm_scene_budget :: StablePtr SceneCell -> Ptr CInt -> Ptr CInt -> IO CInt`、`pm_scene_count :: StablePtr SceneCell -> IO CInt`、`pm_scene_spells :: StablePtr SceneCell -> Ptr CInt -> CInt -> IO CInt` | `src/ffi/Magic/FFI.hs:931, 942, 951` | - | 併發施法後斷言「配額未被重複計入、id 兩兩相異」 |
| `pm_age :: StablePtr SpellCell -> IO CDouble`、`pm_free :: StablePtr SpellCell -> IO ()`、`pm_scene_free :: StablePtr SceneCell -> IO ()` | `src/ffi/Magic/FFI.hs:454, 666, 697` | - | 驗收標準第 2 條的觀測點；併發釋放測試 |
| `pmOk, pmErrJson, pmErrBudget, pmErrCapacity, pmErrArgs, pmErrQuota :: CInt` | `src/ffi/Magic/FFI.hs:205-221` | - | 併發施法的回碼斷言（`pmErrQuota` 用於「超額的那幾個被拒」）；不新增任何常數 |
| `advanceSpell :: FrameInput -> ActiveSpell -> ActiveSpell` | `src/boundary/Magic/Interface.hs:213` | - | 原子步裡的純轉移；一個字不改 |
| `data ActiveSpell = ActiveSpell { asSpell :: !CompiledSpell, asCtx :: !CastContext, asElapsed :: !Double, asField :: !FieldState }` | `src/boundary/Magic/Interface.hs:163-171` | - | **四個欄位全嚴格**，是「WHNF 就夠」的依據（E2） |
| `advanceScene :: FrameInput -> Scene -> Scene`、`dismiss :: SpellId -> Scene -> Scene` | `src/boundary/Magic/Scene.hs:165, 160` | - | 場景側的純轉移 |
| `castInto :: CastRequest -> Scene -> Either CastRefusal (SpellId, Scene)`、`castManyInto :: [Circle] -> CastContext -> Scene -> Either CastRefusal (SpellId, Scene)` | `src/boundary/Magic/Scene.hs:127, 133` | - | `admitInto` 傳進原子步的純決策；E3 證明競爭下不重複求值 |
| `sceneBudget :: Scene -> (Int, Int)`、`sceneSpells :: Scene -> [SpellId]` | `src/boundary/Magic/Scene.hs:107, 102` | - | 併發施法後的配額與 id 斷言 |
| `newSpellHandle :: ActiveSpell -> IO (StablePtr SpellCell)`、`freeSpellHandle :: StablePtr SpellCell -> IO ()`、`newSceneHandle :: Scene -> IO (StablePtr SceneCell)`、`freeSceneHandle :: StablePtr SceneCell -> IO ()` | `.design/subsystems/host-runtime/features/F002-handle-generation.md`「新增的介面」 | **F002** | 註冊表的四個變動點；本功能在它們外面加寫入鎖（尚未實作，依文檔的介面約定相依） |
| `spellRegistryStats :: IO (Int, Int)`、`sceneRegistryStats :: IO (Int, Int)` | `.design/subsystems/host-runtime/features/F002-handle-generation.md`「新增的介面」 | **F002** | 併發施法／釋放後斷言存活數回到起點（同上，文檔相依） |
| `atomicModifyIORef' :: IORef a -> (a -> (a, b)) -> IO b` | `base`（GHC 9.14.1，`Data.IORef`；`ghci :t` 實查） | - | 原子步的唯一原語 |
| `newMVar :: a -> IO (MVar a)`、`withMVar :: MVar a -> (a -> IO b) -> IO b` | `base`，`Control.Concurrent.MVar`（`ghci :t` 實查） | - | 註冊表的表級寫入鎖；`withMVar` 自帶 `mask`／`onException` |
| `newEmptyMVar :: IO (MVar a)`、`putMVar :: MVar a -> a -> IO ()`、`takeMVar :: MVar a -> IO a`、`readMVar :: MVar a -> IO a` | `base`，`Control.Concurrent.MVar`（`ghci :t` 實查） | - | 測試的起跑柵欄與收攏 |
| `forkOn :: Int -> IO () -> IO ThreadId`、`yield :: IO ()` | `base`，`Control.Concurrent`（`ghci :t` 實查） | - | 測試把執行緒釘到 capability；`yield` 用在牙齒檢查的孿生體 |
| `getNumCapabilities :: IO Int`、`setNumCapabilities :: Int -> IO ()`、`getNumProcessors :: IO Int` | `base`，`GHC.Conc`（`ghci :t` 實查；用法沿用 `test/ParallelSampleSpec.hs:25, 186-199`） | - | 測試期間暫時提高 capability 數並還原 |
| `getAllocationCounter :: IO Int64` | `base`，`System.Mem`（`ghci :t` 實查） | - | 單執行緒每次呼叫配置量的確定性斷言 |
| `unsafePerformIO :: IO a -> a` | `base`，`System.IO.Unsafe` | - | 兩把頂層寫入鎖（搭配 `NOINLINE`，手法同 F002 的頂層註冊表） |
| foreign-library 的 `build-depends` 白名單 `base`／`magic-boundary`／`bytestring`／`vector` | `particle-magic.cabal:242-245`，由 `test/FFIContractSpec.hs:237-242` 斷言 | - | **硬性限制**：`stm`、`atomic-primops` 一律不得引入；`atomicModifyIORef'` 與 `MVar` 都在 `base` 內 |
| `test-suite spec` 的 `ghc-options: -Wall -threaded -rtsopts "-with-rtsopts=-N -T"` | `particle-magic.cabal:450` | - | 測試套件**已經**是 `-threaded -N`，併發測試不必改 RTS 設定 |
| foreign-library 的 `ghc-options: -Wall -O2 -threaded` | `particle-magic.cabal:247` | - | 出貨的共享函式庫本來就用 threaded RTS，執行緒模型的承諾在產物上成立 |
| `benchmark bench` stanza（`hs-source-dirs: bench, app`；`build-depends` 含 `base`、`particle-magic:magic-boundary`、`tasty-bench`） | `particle-magic.cabal:456-479` | - | 壁鐘對照組加在這裡，不必改 cabal |
| `ageBy :: Int -> ActiveSpell -> ActiveSpell`、`bench "ring-fire (no fields)" (nf (advanceCost 60) fieldlessSpell)` | `bench/Bench.hs:139-145, 486-490` | - | 對照組沿用的既有形狀與 fixture |
| `castOk :: BS.ByteString -> CastContext -> IO (StablePtr SpellCell)`、`observeRaw :: StablePtr SpellCell -> Int -> Int -> IO Observed`、`data Observed { obCode, obPosX, …, obInfo }`、`spellBytes :: FilePath -> IO BS.ByteString`、`testCtx :: CastContext` | `test/FFIHarness.hs:111, 155, 128-136, 80, 71` | - | 併發測試的施法與觀測 |
| `referenceStates :: BS.ByteString -> [Float] -> [ActiveSpell]`、`referenceAt :: ActiveSpell -> [Float] -> ActiveSpell` | `test/FFIHarness.hs:218, 209` | - | 逐位元比對的參考路徑（循序 N 步） |
| `headerFunctions :: IO [String]`、`headerDefines :: IO [(String, Int)]`、`readUtf8 :: FilePath -> IO String` | `test/FFIContractSpec.hs:283, 314, 351` | - | 標頭守門沿用既有剖析器；哨兵詞比對手法同 `:204-207` 的 `right-handed` |
| `include/particle_magic.h:60, 72-73` 的兩段 threading 散文 | `include/particle_magic.h` | - | 本功能要改寫的過期敘述 |
| `docs/integration.md:448`（§4.4 第二點）、`docs/integration.md:712`（§8「單執行緒 handle」列） | `docs/integration.md` | - | 同上，中文面 |
| `bindings/csharp/ParticleMagic.cs:142`「one scene per thread」註解 | `bindings/csharp/ParticleMagic.cs` | - | 同上，C# 面（只是註解，不影響對帳測試） |

## 新增的介面

### C 面（`include/particle_magic.h`）

**零新增**。無新符號、無新常數、無新結構、`PM_ABI_VERSION` 維持 1、`.def` 不動、不透明型別不變。唯一的改動是把兩段執行緒散文換成 §8 的兩張清單與三句承諾，並埋入哨兵詞。

### C# 面

**零新增**。`bindings/csharp/ParticleMagic.cs` 只改一行註解，進入點與常數集合不變（`test/BindingContractSpec.hs` 的雙向對帳不受影響）。

### Haskell 面（`Magic.FFI`；非 C 契約的一部分，比照既有的 `SpellCell (..)`／`writeErr` 從 Internals 區匯出給測試）

| 簽名 | 說明 |
|---|---|
| `stepCellWith :: IORef a -> (a -> (a, b)) -> IO b` | cell 的原子讀改寫，順帶回報一個結果。新值在回傳前被強制到 WHNF（與既有 `writeIORef $!` 同深度）。純函數在競爭下**只被求值一次**（E3） |
| `stepCell :: IORef a -> (a -> a) -> IO ()` | 上者在 `b ~ ()` 的特例；B 類三個站點用它，`admitInto` 用上者 |

這兩個名字被 T1／T8 的測試直接呼叫，因此**鎖定**（理由同 F001 的 A6 與 F002「新增的介面」：實作自主權在這裡讓渡給可測性）。兩把註冊表寫入鎖是純內部狀態，**不匯出**、名稱不鎖定。

## TodoList

- [x] T1: `stepCell`／`stepCellWith` 兩個原子 RMW 組合子，自 `Magic.FFI` 的 Internals 區匯出；新測試模組 `FFIThreadSpec` 登記進 `particle-magic.cabal` 的 `test-suite spec` `other-modules`  `dep: -`
- [x] T2: 法術推進改走原子步：`pm_advance`（:436-439）；簽名、`withCell` 的 fallback 與檢查順序不動  `dep: T1`
- [x] T3: 場景三個站點改走原子步：`pm_scene_advance`（:864-867）、`pm_scene_dismiss`（:854-857）、`admitInto`（:836-843，純決策進原子步、`poke outId`／`castFail` 留在外面，拒收分支寫回原值）；`withCast` 的 NULL 檢查與 `poke outId (-1)` 順序不動  `dep: T1`
- [x] T4: 註冊表寫入鎖：F002 的四個生命週期函數（`newSpellHandle`／`freeSpellHandle`／`newSceneHandle`／`freeSceneHandle`）各自包進頂層 `MVar ()`（法術與場景各一把）；`withCell`／`withScene` 的解析路徑維持無鎖  `dep: F002`
- [x] T5: 標頭執行緒模型改寫：`include/particle_magic.h:60` 與 :72-73 兩段散文換成「可併發／必須自行序列化」兩張清單加三句承諾，埋入哨兵詞 `no lost updates` 與 `never starts an OS thread`；零符號／常數／結構變動，`PM_ABI_VERSION` 與 `.def` 不動  `dep: T2, T3, T4`
- [x] T6: `docs/integration.md` §4.4（:448）與 §8 限制表（:712）改寫，新增執行緒模型小節（含哨兵詞「不丟更新」）；`bindings/csharp/ParticleMagic.cs:142` 的「one scene per thread」註解更正  `dep: T5`
- [x] T7: `bench/Bench.hs` 新增「handle cell 推進」對照組：同一個真實 `ActiveSpell`，舊形狀（`readIORef` ＋ `writeIORef $!`）與 `stepCell` 形狀各一條 bench，無力場與有力場各一組；前後數字記進「實作備註」。不動 `particle-magic.cabal`  `dep: T2`
- [x] T8: 原子步的失敗語意寫進 `Magic.FFI` 的 haddock 與標頭：內部失敗只毒化該控制代碼，其他控制代碼與宿主進程不受影響（與 F001 合併後表現為之後每次呼叫皆回 `PM_ERR_INTERNAL`）  `dep: T2`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `FFIThreadSpec` — `it "never loses an update, however the threads interleave"` | `stepCell` 對一個 `IORef Int` 做 `(+1)`：T 個 `forkOn` 執行緒（T ＝ 測試期間設定的 capability 數）各 20000 次，起跑柵欄同時放行，最終值**恰為** `T × 20000`。同一骨架另跑一份非原子孿生體（`readIORef` → `yield` → `writeIORef`），它必須至少丟一次更新，否則本條以 `pendingWith "this runner cannot exhibit the race"` 收場（牙齒檢查，見「7.」） |
| T2 | `FFIThreadSpec` — `it "advances one spell handle exactly N steps under contention"` | 一個 `pm_cast_ex` 出來的控制代碼，T 執行緒 × K 次 `pm_advance`（同一個 `dt = 1/60f`，`ring-fire`）：`pm_age` **逐位元**等於同一串 `dt` 循序摺疊的年齡；`observeRaw` 的九欄與 `batch_info` 逐位元等於 `referenceStates` 的第 N 個狀態（`Float` 比位元樣式）。外加原始碼稽核：`src/ffi/Magic/FFI.hs` 不再出現 `writeIORef` |
| T3 | `FFIThreadSpec` — `it "advances, casts into and dismisses one scene without losing an update"` | 三段：(a) T × K 次併發 `pm_scene_advance` 後 `pm_scene_observe` 逐位元等於循序參考；(b) 配額恰好容納 T 個法術時，T 執行緒各 `pm_scene_cast` 一次 → 全數 `PM_OK`、`pm_scene_count` ＝ T、`pm_scene_spells` 的 id 兩兩相異、`pm_scene_budget` 的 used 等於逐一施法的總和（配額未被重複計入）；(c) 配額只容納 M < T 個時，恰好 M 個回 `PM_OK`、其餘回 `pmErrQuota`，且 used 不超過 cap |
| T4 | `FFIThreadSpec` — `it "casts and frees on many threads at once"` | T 執行緒各自跑一整條生命週期（`pm_cast_ex` → K × `pm_advance` → `observeRaw` → `pm_free`，場景側另跑一輪 `pm_scene_new`／`pm_scene_cast`／`pm_scene_free`）：每個執行緒的九欄逐位元等於它自己的單執行緒參考；全部發出的控制代碼字**兩兩相異**；結束後 `spellRegistryStats`／`sceneRegistryStats` 的存活數回到起跑前的值 |
| T5 | `FFIContractSpec` — `it "documents which operations may run concurrently"` | 標頭含 `no lost updates` 與 `never starts an OS thread`，不再含 `one handle is owned by one thread`；兩張清單的關鍵詞（`pm_free`、`pm_shutdown`、`different handles`）都在；`headerFunctions` 的集合、`headerDefines` 與 `PM_ABI_VERSION` 與改寫前完全相同 |
| T6 | `FFIContractSpec` — `it "keeps the integration guide and the C# binding in step with the header's thread model"` | `docs/integration.md` 含哨兵詞「不丟更新」，且不再含「一個 handle 屬於一個執行緒」與「庫內無鎖」；`bindings/csharp/ParticleMagic.cs` 不再含 `one scene per thread` |
| T7 | `FFIThreadSpec` — `it "keeps a single-threaded advance inside its cost envelope"` | 以 `getAllocationCounter` 量固定次數 `pm_advance`（`ring-fire`）的每次呼叫配置量：小於一個明列的常數上限，且在「存活 1 個控制代碼」與「存活 1024 個控制代碼」兩種規模下**相同**（解析路徑仍是一次查表）。壁鐘那一半由本項的 bench 對照組提供，數字記進「實作備註」 |
| T8 | `FFIThreadSpec` — `it "poisons only the handle whose step failed"` | 用 `newSpellHandle` 造兩個控制代碼；對第一個做一次會拋的 `stepCell` → 拋出，且之後對它的每一次讀取／推進都再拋（毒化，符合設計）；**第二個控制代碼完全不受影響**，`pm_advance` ＋ `observeRaw` 仍逐位元等於參考；測試進程存活到本模組結束 |

## 待確認假設

- **A1**: 驗收標準第 4 條「單執行緒 bench 的每次呼叫成本不因本項上升」在奈秒解析度上無法字面成立——原子 RMW 實測 +6.5 ns、+80 B／次推進（§5） → 採取：讀作**「宿主每幀付的成本不上升」**，並提出兩條可機械檢查的門檻取代它：(a) 純核心的 `sample` 與 `advanceSpell` 兩個既有 bgroup 的數字在雜訊內不動（本功能一個位元都沒改它們）；(b) 新的 cell 對照組中，`stepCell` 相對舊形狀的差額 ≤ 20 ns 且 ≤ 100 B／次呼叫 → 影響：若編排者堅持字面的「零上升」，唯一的出路是放棄 C2.2 的「同一控制代碼不丟更新」，或改寫成裸 `casMutVar#` 的 CAS 迴圈（`atomic-primops` 在白名單外、裸 primop 有 ticket 語意的坑），兩條都需要回頭改 ADR-022 D4。
- **A2**: `atomicModifyIORef'` 的失敗會毒化該控制代碼的 cell（今天的 `writeIORef $!` 不會，實測確認） → 採取：**接受並寫進文件與測試**（§6、T8），理由是能拋的來源在此幾乎不存在、後果收斂在單一控制代碼、且與 F001 合併後表現為持續明確的 `PM_ERR_INTERNAL` → 影響：若裁定「內部失敗後控制代碼必須仍可用」，原子步得改成「先強制、再交換」的自製 CAS 迴圈（等於做兩遍功或動 primop），T8 要改成相反的斷言，§6 整段重寫。
- **A3**: 註冊表的同步原語——F002 接縫的字面建議是「頂層 `IORef` 改 `MVar`」 → 採取：**保留 `IORef` 供無鎖解析，另加一把只在配置／釋放時取的頂層 `MVar ()` 寫入鎖**（法術與場景各一把），因為把解析也改成 `readMVar` 會讓每一次 `pm_advance`／`pm_observe` 都付一次 take／put，直接違反 C2.2 的「單執行緒宿主零額外成本」 → 影響：若裁定照字面把註冊表改成 `MVar Registry`，解析路徑每次呼叫多約 8–15 ns 且會與施法互相阻塞，A1 的成本論述要重算；設計的其餘部分（原子步、文件、測試）不受影響。
- **A4**: 併發測試在只有一個處理器的機器（或 CI 的單核 runner）上無法重現競爭 → 採取：**斷言照跑（正確性在任何機器上都必須成立），只有牙齒檢查在孿生體沒丟更新時轉為 `pendingWith`**，並以確定性的原始碼稽核（T2）當主要防線 → 影響：若編排者要求併發測試在單核機器上也必須「證明競爭發生過」，就得引入可控制的排程注入（例如把原子步拆成可插入 `yield` 的測試專用版本），那會讓被測物與出貨物不是同一段程式碼，本文件不採。
- **A5**: `pm_free` 與同一控制代碼的其他呼叫併發時的結果 → 採取：**列為宿主必須自行序列化的操作**（§3、§8），庫只保證「兩種結果都不崩潰」（由 F002 的世代標籤負責，見其逐符號回傳表） → 影響：若要求庫也保證這一條（例如引用計數的控制代碼），F002 的註冊表要加計數欄位、`pm_free` 的語意會從「立刻失效」變成「最後一個使用者離開才失效」，那是 C2.3 的變更，需回寫 `design.md` 並補 ADR。
- **A6**: 本功能是否要一併驗證 out-of-process（真的載入 `.dll`／`.so`）的執行緒模型 → 採取：**不做**，in-process 的 hspec 打到的是同一段 Haskell 程式碼，而載入產物是 F006 的地盤（I6） → 影響：若編排者要 F006 一併涵蓋執行緒模型，F006 的純 C 宿主要多開執行緒，是加法，不需要改本文件的任何設計。

## 實作備註

實作於 2026-08-21，在 F002／F001／F003／F005／F007 已合併的基底上。測試 **1838 → 1846**（新增 8 條：`FFIThreadSpec` 6 條、`FFIContractSpec` 2 條），全綠、零 pending、既有測試一條未改語意。

### 設計期四項查證的實作後複驗

- **E1 不丟更新**（T1，`FFIThreadSpec`）：8 個 `forkOn` 執行緒各 20000 次遞增。`stepCell` 版得到 **160000／160000**；同一骨架的非原子孿生體（`readIORef` → `yield` → `writeIORef`）在本機**確實丟了更新**，所以牙齒檢查沒有轉 `pendingWith`——綠色是驗過的，不是空轉的。
- **E2 WHNF 強制深度**：照設計成立，由 T8 的毒化行為反證（`atomicModifyIORef'` 先安裝後強制，所以會拋的新值留在 cell 裡；若沒有強制，例外根本不會在 `stepCell` 內出現）。
- **E3 純函數只被求值一次**：由 T3(c) 在競爭下反證——配額只容納 M 個法術時，T 個執行緒併發施法**恰好** M 個 `PM_OK`、其餘 `PM_ERR_QUOTA`。若落敗的 CAS 會重複求值並提交，通過數會超過 M。
- **E4 成本**：見下。

### E4 重新實測（`cabal bench --pattern "handle cell advance"`，GHC 9.14.1、`-O2 -threaded`、Windows x86_64、1000 步／iteration）

| 形狀 | `-N1` | `-N8` |
|---|---|---|
| ring-fire（無力場）／舊的讀改寫 | 2.62 ns／步 | 4.60 ns／步 |
| ring-fire（無力場）／`stepCell` | 8.61 ns／步 | 13.4 ns／步 |
| gravity-well（2 力場）／舊的讀改寫 | 14.9 µs／步 | 20.6 µs／步 |
| gravity-well（2 力場）／`stepCell` | 14.6 µs／步 | 17.7 µs／步 |

- 無力場的差額 **+5.99 ns（`-N1`）／+8.8 ns（`-N8`）**，與設計期估的 +6.5 ns 一致，且都在 A1(b) 的 **≤ 20 ns** 門檻內。
- 有力場的兩列差額**落在雜訊裡**（原子版名目上還快一點）：固定成本在真實工作量旁邊看不見。
- **配置量**（T7，`getAllocationCounter`）：`pm_advance` 每次呼叫 **248 B**，且在「存活 1 個控制代碼」與「存活 1025 個控制代碼」下**完全相同**（248 = 248）——解析仍是一次查表，不隨表大小變。斷言上限 512 B，兩種規模差額斷言 ≤ 8 B。
- **A1(a)**：`sample`／`advanceSpell` 兩個既有 bgroup 的數字不必重測即成立——`git diff --stat` 顯示 `src/core/` 與 `src/boundary/` **一個檔案都沒改**。

### 與設計文件的差異（都在實作自主權內，記錄備查）

1. **B 類站點是六個，不是四個**。F005 合併後多了 `pm_advance_ex`（`src/ffi/Magic/FFI.hs:695`）與 `pm_scene_advance_ex`（:1170），兩者同樣是推進、同樣要不丟更新，一併改走 `stepCell`。設計預留的「單一掛點」正好就是為此。
2. **註冊表寫入鎖放在 `Magic.FFI.Registry` 內，不是 `Magic.FFI` 的四個生命週期函數外**（依閘門裁決）。`MVar ()` 成為 `Registry` 值的一個欄位（`Registry !HandleKind !(MVar ()) !(IORef (Table a))`），由 `newRegistry` 建立，`registryInsert`／`registryRelease` 各自整段包在 `withMVar` 內。效果與 A3 完全相同——法術與場景各一把鎖、解析路徑一個字不改——但保證覆蓋所有變動（包含未來新增的呼叫端），而不只覆蓋今天那四個包裝函數。22 個呼叫端一行未動。
3. **`Magic.FFI` 的散文不得再出現 `writeIORef` 字面**。T2 的原始碼稽核是逐字比對，而註解裡談「舊形狀」時自然會寫到這個字。四處註解改寫為 “write-back”／“strict write-back”，語意不變、稽核得以是逐字的。
4. **T8 的毒化用兩段驗證**：(a) 對一個純 `IORef Int` 直接 `stepCell (\_ -> error …)`，證明組合子本身的失敗語意（拋出，且之後每次讀都再拋）；(b) 用 `newSpellHandle (error …)` 造一個控制代碼，`pm_advance_ex` 的原子步在它身上失敗，之後**持續**回 `PM_ERR_INTERNAL`、`pm_age` 持續回 `-6.0`，而鄰居控制代碼的九欄仍逐位元等於參考。兩段合起來就是設計要的「只毒化該一個控制代碼」。
5. **併發步數改為固定總量而非固定每執行緒量**（防偽陰性）。首版寫成「每執行緒 1000 步」，在 T4／T8 的單控制代碼路徑上只有 0.12 s 的法術年齡，ring-fire 此時**還沒有粒子**，逐位元比對會退化成兩個空 buffer 相等——正是 F005 踩過的那個坑。改為 `raceSteps = 8192` 總步數（`raceDt = 1/8192 s`，即恰好 1.0 s 法術年齡，此時 ring-fire 有 2049 粒），競爭時再除以執行緒數；**每一次逐位元比對前都先斷言 `liveParticles > 0`**。
6. **壁鐘對照組的兩個形狀在 `bench/Bench.hs` 內就地寫出**，不 import `Magic.FFI`——bench stanza 只相依 `magic-core`／`magic-boundary`，構不到 foreign-library，而 `stepCell` 本來就是 `atomicModifyIORef'` 的一行薄殼，所以量到的是同一串指令。`particle-magic.cabal` 的 bench stanza 一個字沒改（只在 `test-suite spec` 的 `other-modules` 加了 `FFIThreadSpec`）。

### 硬性約束的收尾對帳

| 約束 | 結果 |
|---|---|
| `build-depends` 白名單 base／magic-boundary／bytestring／vector | 未動；`stm`／`atomic-primops` 未引入（`MVar`、`atomicModifyIORef'` 都在 `base`）。`FFIContractSpec` 的白名單斷言照舊綠 |
| C 面零新增符號／常數／結構 | `headerFunctions` 仍是 35、`headerDefines` 不變、`PM_ABI_VERSION` 仍是 1、`particle-magic-ffi.def` 未動 |
| 三層包裝的守門測試 | `FFIFirewallSpec` 的 32 個 `foreign export` 全在防火牆內、`FFIContractSpec` 的 `foreignExportSymbols ≡ pm_hs_ ＋ (headerFunctions \ 三個 lifecycle)` 皆綠——本功能只改本體，未動任何 `foreign export` 行 |
| 標頭只改執行緒散文＋埋哨兵 | `no lost updates`、`never starts an OS thread` 已在；`one handle is owned by one thread` 已移除（T5 逐字斷言三者） |
