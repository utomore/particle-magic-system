---
id: integration-guide
type: reference
title: host-integration-guide
description: 各語言宿主怎麼接上本系統的整合指南與資料合約
status: done
created: 2026-08-14
updated: 2026-08-16
related-adr: [adr-0008, adr-0011, adr-0012]
related-spec: [func-0009, func-0011, func-0018]
---

# 宿主整合指南

> 版本：1.3（2026-08-16，enhance-0001 落地後：**母語路線補上可跑的範例**——§1 的路線表加一欄「可跑的範例」、§3 開頭補齊 `bytestring`／`vector` 兩個容易漏的依賴並指向 [`examples/haskell/`](../examples/haskell/)、新增 **§3.3「2D／像素風宿主食譜」**（五步，不分語言，§4.5 交叉指路）、§8 新增一列誠實記帳「像素風只有食譜，沒有像素風的參考實作」。合約零變更：沒有新語意、沒有動 JSON schema、ABI version 仍為 1）
> 1.2（2026-08-16，spec 0018 交付後：場景層整個上 C ABI——新增 §4.6、`PM_ERR_QUOTA` 進 §4.3 的錯誤表、§3.2 與 §8 的「只在 Haskell 面」收窄為「不進場景的合成只在 Haskell 面」。ABI version 仍為 1——全部是加法。1.1 為 spec 0011 交付後：投影三件套上 C ABI、C# 參考綁定與 Unity 範例成為真檔案）
> 對象：想把這套粒子魔法系統接進自己遊戲的人——Unity、Godot、C/C++ 引擎、Haskell 專案，或完全自製的前端。
> 相關文件：[architecture.md](arch/architecture.md)（系統設計）、[roadmap.md](roadmap.md)（還缺什麼）、[`include/particle_magic.h`](../include/particle_magic.h)（凍結的 C 合約）、[`bindings/csharp/ParticleMagic.cs`](../bindings/csharp/ParticleMagic.cs)（C# 參考綁定）、[`examples/haskell/`](../examples/haskell/)（Haskell 最小宿主）、[`examples/c/`](../examples/c/)（C 最小宿主）、[`examples/unity/`](../examples/unity/)（Unity 最小範例）

---

## 0. 一句話心智模型

> **JSON 進，六條陣列出。這個庫一行畫圖的程式碼都沒有，也永遠不會有。**

你給它一張魔法陣（JSON 文字）、施法者的位置與面向、一個亂數種子，然後每幀給它一個 `dt`；它回你一批粒子的 **SoA（Structure of Arrays）**——六條等長陣列（x、y、z、size、life、color），外加「哪一段屬於哪個批次、該用什麼混合模式」的描述。

把那六條陣列餵進你自己的頂點緩衝、用你自己的材質畫出來——那部分是你的引擎的工作，不是這個庫的。這不是偷懶，是[架構決策](adr/adr-0008-dimension-agnostic-3d-first.md)：庫的輸出不含任何渲染後端的假設，所以換引擎、換維度、換語言都不需要改核心。

**確定性保證**：同一組 `(JSON, 位置, 面向, seed, dt 序列)` 永遠產生逐位元相同的輸出——同一台機器、不同平台、Haskell 路徑或 C ABI 路徑都一樣。這讓法術可回放、可存檔（只要存那五樣東西）、可用純函數測試。

---

## 1. 選一條路

| 你的宿主是…… | 走這條 | 章節 | 可跑的範例 |
|---|---|---|---|
| Haskell 專案 | cabal sublibrary，直接 import | [§3](#3-路線-ahaskell-宿主) | [`examples/haskell/`](../examples/haskell/) |
| Unity（C#） | C ABI＋P/Invoke | [§5](#5-路線-cunity-c) | [`examples/unity/`](../examples/unity/) |
| Godot、Unreal、自製 C/C++ 引擎 | C ABI，直接 `#include` | [§4](#4-路線-bcc-宿主) | [`examples/c/`](../examples/c/) |
| 其他任何能載入共享庫的語言（Rust、Zig、Python…） | C ABI，用該語言的 FFI | [§6](#6-路線-d自製前端與其他語言) | 同上 |

**畫面是 2D 或像素風的話**，選完路線再看 [§3.3](#33-2d像素風宿主食譜)——那一節不分語言，只講「怎麼把抽象 3D 座標落到你的像素格上」。

除了第一條，全部走同一份合約：`include/particle_magic.h`。那份 header **就是全部的合約**，而且是凍結的——只會增加宣告，不會改動或移除既有的任何一個。`pm_abi_version()` 讓你在啟動時確認手上的 `.dll` 與你編譯時的 header 同一代。

---

## 2. 資料合約速查

不管走哪條路，你拿到的東西都是同一份，只是型別的包裝不同。

### 2.1 六條欄位

| 欄位 | 型別 | 意義 |
|---|---|---|
| `pos_x` / `pos_y` / `pos_z` | `float` | 粒子在**抽象 3D 世界座標**的位置 |
| `size` | `float` | 粒子的半邊長（世界單位）。billboard 的邊長 = `2 × size` |
| `life` | `float` | 正規化生命週期 0..1（0 = 剛生成，1 = 即將消失）。做淡出、做 LOD、做 shader 變化都靠它 |
| `color` | `uint32` | **`0xRRGGBBAA`**——R 在最高位元組、A 在最低位元組 |

**顏色解包**（0011 起 header 自己也寫了這一段）：

```c
uint8_t r = (c >> 24) & 0xFF;
uint8_t g = (c >> 16) & 0xFF;
uint8_t b = (c >>  8) & 0xFF;
uint8_t a =  c        & 0xFF;
```

顏色是**依 `life` 沿著顏色曲線內插後的結果**，屬性（火／雷／⋯）決定曲線兩端，所以你拿到的已經是最終顏色，不需要自己查表。Alpha 通常在生命末端歸零——直接乘進頂點色即可。

### 2.2 批次描述 `batch_info`

粒子在六條陣列裡是**連續分段**存放的，每段是一個批次（batch）。`pm_observe` 回傳批次數 `n`，並填好 `n × 4` 個 int：

| 索引 | 意義 |
|---|---|
| `batch_info[4*i + 0]` | 第 i 批的第一顆粒子在六條陣列裡的位移（offset） |
| `batch_info[4*i + 1]` | 第 i 批的粒子數 |
| `batch_info[4*i + 2]` | 混合模式：`PM_BLEND_ALPHA`(0) / `PM_BLEND_ADDITIVE`(1) |
| `batch_info[4*i + 3]` | billboard 形狀：`PM_SHAPE_SQUARE`(0) / `PM_SHAPE_SOFT_DOT`(1) / `PM_SHAPE_RING`(2) / `PM_SHAPE_SPARK`(3)。不認得的碼照 `PM_SHAPE_SQUARE` 畫即可（func-spec 0015 起，形狀由魔法陣的 `style` 符文指定） |

一批＝一次 draw call（設好混合狀態，畫這一段）。目前每個法術的批次數很少（個位數），`max_batches = 8` 足夠；不夠時 `pm_observe` 回 `PM_ERR_CAPACITY` 而**不寫入任何東西**——你不會拿到畫到一半的幀。

### 2.3 座標系與單位

- **座標系：OpenGL 式右手系——X 右、Y 上、+Z 朝觀者。**（0011 起 header 檔頭也寫了這一段。）這件事被 `vortex` 力場的外積固定住（旋轉方向是真的有手性的），所以**手性錯了不會崩潰，只會讓漩渦轉反**。
  - Unity / Unreal 是**左手系**（+Z 進畫面）→ 見 [§5.5](#55-座標系轉換)。
  - raylib / OpenGL / Godot 3D 是右手系 → 直接用。
- **時間**：秒。`dt`、`pm_age()` 都是秒。
- **長度**：任意世界單位，由魔法陣 JSON 裡的數字決定（`size: 3.0` 的方陣就是 3 個單位寬）。你自己決定 1 單位是 1 公尺還是 1 像素。

### 2.4 固定時步

模擬假設**固定 `dt`**（[architecture §11](arch/architecture.md#11-不容易擴充與改動的地方明知的代價) 把它列為系統公理）。力場層的確定性與可回放性依賴這一點。

正確做法是 accumulator：渲染幀率浮動，模擬永遠走固定步。累加器是**你的**，但那段算術不必你寫——`pm_plan_steps()` 就是庫自己用的那一份：

```c
#define FIXED_DT_F (1.0f / 60.0f)           /* pm_advance_ex 收的 */
#define FIXED_DT   ((double)FIXED_DT_F)     /* pm_plan_steps 規劃用的 */
#define MAX_STEPS_PER_FRAME 8

static double acc = 0.0;                    /* 累加器，雙精度 */
int steps;

pm_plan_steps(FIXED_DT, MAX_STEPS_PER_FRAME, frame_time, acc, &steps, &acc);
while (steps-- > 0) {                       /* 每步都 advance */
    pm_advance_ex(spell, FIXED_DT_F);
}
pm_observe(spell, ...);                     /* 每個畫面幀只取樣一次 */
```

三件事值得知道：

- **單幀最大步數是死亡螺旋防護**。手寫的 `while (acc >= dt)` 沒有上限：一次關卡載入的卡頓、一個中斷點，就會在單幀要求上百步，於是下一幀更晚、要求更多步。規劃器截斷在 `MAX_STEPS_PER_FRAME`，並**丟棄剩下的積壓**——模擬變慢，而不是凍結。範例取的 `8` 沿用本 repo demo 外殼跑完整個 POC 的值（`app/Main.hs` 的 `lcMaxStepsPerFrame`）。
- **規劃器是雙精度**，推進的 `dt` 是單精度。累加器用 `float` 會對著雙精度的模擬慢慢漂，所以 `FIXED_DT` 由 `FIXED_DT_F` 加寬而來，兩邊永遠是同一個數。
- **和 Haskell 面同一份實作**（`Magic.Step.plan`）。C 宿主與 Haskell 宿主餵同一串幀時間，會排出逐位元相同的步數序列。

`pm_advance` / `pm_advance_ex` 只推進時鐘（有力場時順便積分），取樣發生在 `pm_observe`——所以「一幀跑三個固定步」不會付三倍的取樣成本。`pm_advance_ex` 與 `pm_advance` 對合法的 `dt` 執行完全相同的程式碼，只多一個錯誤碼通道。

### 2.5 六條陣列要開多大

**用 `pm_max_particles()` 查，不要用 `PM_MAX_PARTICLES` 常數。**

兩者的意義不同：header 是凍結合約，`PM_MAX_PARTICLES` 因此**永遠**停在第 1 代的 4096；`pm_max_particles()` 是執行期查詢，核心上限提升時它跟著變。用查詢配置的宿主換一顆新版 DLL 就直接受惠，用常數的宿主會在大法術上收到 `PM_ERR_CAPACITY`（整幀不畫，不會壞掉，但你也看不到東西）。

**這件事已經發生過一次**：func-spec 0012 把核心上限從 4096 提到 **16384**，header 一字未改。用查詢的宿主什麼都不用做；用常數的宿主仍然跑得動每一個 4096 粒以內的法術，只是拿不到更大的。

```c
int cap = pm_max_particles();
float* px = malloc(cap * sizeof(float));   /* ... 六條 */
```

可執行的完整版在 [§4.2](#42-最小完整迴圈) 與 [`examples/c/main.c`](../examples/c/main.c)——這一條規則曾經只寫在這裡、範例卻用常數配置，所以現在兩邊由同一支守門測試（`test/ExampleLoopSpec.hs`）釘在一起。

Haskell 宿主無此問題（`observeSpell` 回的 buffer 自己帶長度）。

---

## 3. 路線 A：Haskell 宿主

`magic-core` 與 `magic-boundary` 都是 `visibility: public` 的具名 sublibrary，外部 cabal 專案可直接依賴。

```cabal
-- cabal.project
source-repository-package
  type: git
  location: https://github.com/utomore/particle-magic-system.git
  tag: <commit-or-tag>
```

```cabal
-- your-game.cabal
build-depends: particle-magic:magic-boundary
             , bytestring     -- loadCircle 吃原始位元組
             , vector         -- ParticleBuffer 是 Data.Vector.Unboxed 上的 SoA
```

後兩個容易漏：**編碼與緩衝表徵都是宿主的事**。`Magic.Codec.loadCircle` 收的是檔案的原始位元組（庫不猜編碼），而 `ParticleBuffer` 的六條欄是 `Data.Vector.Unboxed`（[ADR-0006](adr/adr-0006-soa-unboxed-buffer.md)），所以任何要**讀**那六條欄的宿主都需要 `vector`。

**這一整節現在有一個編得起來、跑得動的版本**：[`examples/haskell/`](../examples/haskell/)——一個不畫圖的最小宿主，載入一張陣、跑 120 個固定時步、每幀印一行。它是**獨立的 cabal package**（根目錄的 `cabal build all` 不涵蓋它），因為只有這樣它才真的走過一次外部消費者走的路。逐幀輸出凍結在 `expected-output.txt`，而 `test/ExampleHostSpec.hs` 用兩條各自獨立的路徑（`Magic.Interface` 與 C ABI）重算並比對它。

你只 import 下面這幾個模組，其他一律不是合約的一部分：

```haskell
import Magic.Codec      (loadCircle, renderLoadError)
import Magic.Interface  -- castSpell / advanceSpell / observeSpell / isFinished / spellAge
                        -- ＋ maxSpellParticles / budgetPlanOf / emitterBounds（見 §3.1）
import Magic.Projection (ViewPlane (..), orthographic, depthOrder)   -- 只有 2D 宿主需要
import Magic.Columns    (fromColumns)   -- 只有「手上已經是六條裸欄」的工具需要（0011）
```

`Magic.Columns.fromColumns` 是給已經持有六條欄位的消費者（例如自己的匯入工具）把它們**驗證後**變回 `ParticleBuffer` 的窄門——六欄不等長就回 `Left (LengthMismatch …)`，不會造出壞掉的 buffer。一般宿主用不到：`observeSpell` 給你的本來就是 buffer。

```haskell
runSpell :: BS.ByteString -> IO ()
runSpell bytes =
  case loadCircle bytes of
    Left err -> putStrLn (renderLoadError err)
    Right circle ->
      case castSpell (CastRequest circle ctx) of
        Left cerr   -> print cerr
        Right spell -> loop spell
  where
    ctx = CastContext { casterPos = V3 0 0 0, casterFacing = V3 0 0 1, seed = Seed 42 }

    loop spell = do
      -- 固定時步：一幀可能推進好幾步，但只取樣一次
      let spell' = iterate (advanceSpell (FrameInput dt)) spell !! steps
          FrameOutput bs = observeSpell spell'
      mapM_ drawWithYourRenderer bs      -- rbParticles / rbBlend / rbShape
      if isFinished spell' then pure () else loop spell'
```

`stepSpell` 是 `advanceSpell` 後接 `observeSpell` 的合成，一幀一步時用它比較短。

**2D 宿主**：`orthographic plane p` 回 `(V2, depth)`，`depthOrder plane buffer` 回一個**穩定的由遠而近索引置換**（等深時保持 buffer 原序）。螢幕原點與縮放仍然是你的事——庫只負責丟軸與排序這兩件純數學。

### 3.1 預算與空間範圍（func-spec 0010 新增）

同樣從 `Magic.Interface` 匯出，都是純函數，都可以在第一幀之前就問：

```haskell
maxSpellParticles :: Int                    -- 單一法術的粒子上限（= 編譯期護欄，目前 16384）
budgetPlanOf      :: ActiveSpell -> ParticleBudget
emittersOf        :: ActiveSpell -> [EmitterSpec]
emitterBounds     :: CastContext -> Seconds -> EmitterSpec -> (V3, V3)

data ParticleBudget = ParticleBudget
  { budgetPerEmitter :: U.Vector Int   -- 每個發射器一格，與 emittersOf 同序
  , budgetTotal      :: Int            -- 其總和：這次施法的最壞情況粒子數
  }
```

- **`maxSpellParticles`** 是配置緩衝的正確依據，而不是把數字抄進你的程式碼——它已經從 4096 變成 16384 一次了（func-spec 0012）。C ABI 側的等價查詢是 `pm_max_particles()`（func-spec 0011 交付）。
- **`budgetPlanOf`** 給的是**這一次施法**的上限（`budgetTotal`），通常遠小於 `maxSpellParticles`。想預先配置剛好夠用的頂點緩衝就用它。
- **`emitterBounds ctx horizon em`** 回一個**保守的世界座標 AABB**：這個發射器在 `[0, horizon]` 秒內取樣得到的每一顆粒子都在盒內。它刻意不做視錐剔除——核心沒有相機概念（ADR-0008），要不要因為整個發射器在畫面外而跳過它，是你的決定。`horizon` 是**你選的時窗**：傳一個涵蓋整個法術的秒數就得到全程包絡，傳 `0.5` 就是問「接下來半秒它最遠會跑到哪裡」。傳得越長，盒子越保守。
- `EmitterSpec` 在這裡是**不透明型別**：從 `emittersOf` 拿到，交回給 `emitterBounds`，不要試圖解構它。

```haskell
-- 例：整個發射器在畫面外就不畫它（未來 0.5 秒內都不會進畫面）
visibleEmitters :: CastContext -> ActiveSpell -> [(Int, (V3, V3))]
visibleEmitters ctx spell =
  [ (i, box)
  | (i, em) <- zip [0 ..] (emittersOf spell)
  , let box = emitterBounds ctx (Seconds 0.5) em
  , yourFrustumTest box
  ]
```

#### 3.1.1 更緊的盒與佔用格網（func-spec 0025 新增）

`emitterBounds` 的立方體很鬆——一道沿法線射出 8 units 的光束，X／Y 兩軸也被撐到 8。0025 補上一組**貼合**的查詢，全部同樣從 `Magic.Interface` 匯出、全部是純函數、全部 **opt-in**（不呼叫就零成本，`FrameOutput` 一個欄位都沒加）：

```haskell
emitterBoxOf  :: ActiveSpell -> EmitterSpec -> OrientedBox   -- 這個發射器「目前」到哪
spellBoundsOf :: ActiveSpell -> (V3, V3)                     -- 整道法術「這輩子」的 AABB
spellBoxOf    :: ActiveSpell -> OrientedBox                  -- 同上，有向盒
occupancyOf   :: Int -> ActiveSpell -> OccupancyGrid          -- N³ 佔用計數
occupancyMask :: ActiveSpell -> Word32                        -- N = 3 的快路徑

data OrientedBox = OrientedBox
  { obCenter :: V3
  , obAxisU, obAxisV, obAxisN :: V3   -- 單位正交：面右、面上、面法線
  , obHalfU, obHalfV, obHalfN :: Float
  }
```

三件要知道的事：

1. **有向盒比 AABB 緊得多**（實測各範例陣是 `emitterBounds` 體積的 1.5%–13%），因為行進距離只算進法線軸。你的碰撞層若只吃 AABB，用 `boxToAABB` 轉一次即可。
2. **兩種時窗，刻意不同**：`emitterBoxOf` 用**當前年齡**（這一幀該不該剔除它），`spellBoundsOf`／`spellBoxOf` 用**整個生命週期**（這道法術會不會碰到那面牆）。後者因此在法術全程**不變**。
3. **格網的框固定不動**（＝`spellBoxOf`）。第 5 格在第 10 幀和第 11 幀指的是同一塊空間，所以「粒子進入某區域」這種事件偵測才寫得出來。索引序是 `(k*N + j)*N + i`，`i` 沿 U、`j` 沿 V、`k` 沿法線。

N = 3 時 27 格恰好塞進一個 `Word32`：`occupancyMask` 一次查詢就給你「哪些格子是活的」，broad phase 是一次 `popCount` 或位元 AND，零配置。

這些查詢**只讀**：呼叫前後 `observeSpell` 的輸出逐位元相同。核心仍然不做視錐剔除也不做碰撞判定——它交的是資訊，判定是你的（ADR-0019）。

成本誠實說：`occupancyOf` 是單趟 O(粒子數)，實測 **24 ns／粒**（256 粒 ≒ 8 µs，粒子上限 16384 粒 ≒ 0.40 ms）。典型法術可以每幀問；上限附近的法術每幀問就要自己算一下預算。

### 3.2 多陣合成與場景層（func-spec 0012 新增；場景層已於 0018 上 C ABI）

**合成**——把幾張陣當成一個法術施放：

```haskell
castSpells :: [Circle] -> CastContext -> Either CompileError ActiveSpell
```

回來的是一個普通的 `ActiveSpell`，`advanceSpell`／`observeSpell`／`isFinished` 全部照舊。語意（ADR-0012）：

- 粒子是各成分的**疊加**——取樣輸出就是各成分的輸出串接，逐位元；
- 生命週期的四個界標**逐一取最大值**，於是合成陣的每個階段持續到最慢的成分結束，誰都不會被截斷；
- 預算**相加**，並對**同一個** `maxSpellParticles` 檢查——合成不是提高上限的手段，兩張各自合格的陣加起來仍可能回 `BudgetExceeded`（帶合成後的總需求）；
- 力場**融合**：任一成分的場作用於整個合成法術的粒子（把重力井疊上火環，火會被吸過去）；
- 混合模式取**第一張陣**的（見 §8 的限制列）。

`castSpells [c] ctx` 與 `castSpell (CastRequest c ctx)` 逐位元相同，所以既有呼叫端不必改。

**場景層**——多個法術在一個全域配額下共存：

```haskell
import Magic.Scene

newScene     :: SceneConfig -> Scene                -- SceneConfig { scGlobalCap :: Int }
castInto     :: CastRequest -> Scene -> Either CastRefusal (SpellId, Scene)
castManyInto :: [Circle] -> CastContext -> Scene -> Either CastRefusal (SpellId, Scene)
dismiss      :: SpellId -> Scene -> Scene
advanceScene :: FrameInput -> Scene -> Scene        -- 推進全部，移除已完成者
observeScene :: Scene -> FrameOutput                -- batch 串接，SpellId 升冪
sceneBudget  :: Scene -> (Int, Int)                 -- (已用, 上限)
sceneSpells  :: Scene -> [SpellId]
```

`Scene` 是純值，和 `ActiveSpell` 一樣沒有 IO、沒有鎖。配額是**先到先得**：塞不下就回 `QuotaExceeded 需求 剩餘`，而且場景一個位元都不變；法術結束時 `advanceScene` 把它移除，配額自動回收（已用量是從現存法術即時求和的，沒有第二本帳）。

```haskell
frame :: FrameInput -> Scene -> (Scene, FrameOutput)
frame fi scene = let scene' = advanceScene fi scene in (scene', observeScene scene')
```

進階配額策略（按強度加權、優先權搶佔）刻意不做：庫給的是拒收與剩餘量，要先 `dismiss` 掉什麼是遊戲的決定，不是粒子系統的（ADR-0012 D6）。

**這一節的每一行,C 宿主現在也有**（func-spec 0018,見 §4.6）。上表左欄逐項對應 `pm_scene_*`,語意一字不差——C 面是這張匯出表的型別穿越,沒有第三件事。**合成**（`castSpells` → 不進場景的 `ActiveSpell`）則仍只在 Haskell 面:C 宿主要合成,開一個 `global_cap` 夠大的場景、用 `pm_scene_cast_many` 即可。

### 3.3 2D／像素風宿主食譜

**這一節不分語言。** 它掛在 §3 底下只是編號的方便：除了第 1 步的程式碼片段是 Haskell 的，其餘每一條對 C／C# 宿主一字不差適用（C 側的投影入口是 `pm_project`／`pm_depth_order`，見 [§4.5](#45-2d-宿主投影與深度排序0011-新增)）。

庫這一側該給的都給了：`orthographic` 丟一軸、`depthOrder` 給 painter 置換、`rbShape` 只是一個 tag、16384 的上限對像素風是天文級的過剩。但一個實際要動手的 2D 宿主會撞到五件庫**不會**替你決定的事——而且**五件都不會報錯**，做錯只會讓畫面「怪但說不出哪裡怪」。

#### 1. 先選視角，再選 `casterFacing`（唯一一條錯了會靜默塌掉的）

法術的幾何是這樣長出來的：**初始面垂直於 `casterFacing`，立體擴充沿著 `casterFacing` 前進**（`Magic.Compile` 的 `Anchor`：局部 +Z ＝ facing，骨架法線 ＝ +Z）。所以**視角丟掉哪一軸，facing 就絕對不能指向那一軸**。

| 遊戲類型 | `ViewPlane` | 丟掉的軸 | `casterFacing` 該躺在 | 例 |
|---|---|---|---|---|
| 側視卷軸（platformer、橫向 STG） | `SideXY` | Z | XY 平面內 | `V3 0 1 0`——地上一個陣、光柱往畫面上方射 |
| 俯視（Zelda 式、twin-stick） | `TopXZ` | Y | XZ 平面內 | `V3 0 0 1`——陣立在地面上、往角色前方延伸 |
| 斜俯視 3/4 | 目前用 3D 相機拉俯角，不是正交平面 | — | 隨遊戲 | 見下方註 |

**選錯的症狀**：俯視宿主留著 `V3 0 1 0`（很自然的預設，demo 用的就是它），擴充方向恰好是被丟掉的那一軸，**整根柱子塌成它自己的足跡**。你會看到陣，但看不到它在動。沒有錯誤碼、沒有崩潰——這一條的性質和 [§5.5](#55-座標系轉換) 的手性完全一樣（翻錯 Z 只有 `vortex` 轉反）。

> **3/4 斜俯視**：`ViewPlane` 目前只有正的兩個平面，沒有帶俯角的建構子。斜俯視的做法是**用 3D 相機拉俯角**（demo 的 `App.Camera`，elevation 約 35–45°），深度排序照 3D 那條路走。把帶俯角的正交投影變成正式支援的輸出平面是一份獨立的 spec，不在目前的合約裡。

#### 2. 選 pixels-per-unit

`size` 是**世界單位的半邊長**，billboard 的邊長 ＝ `2 × size`。落到像素：

```
邊長（像素） = 2 × size × PPU
```

最省事的慣例是 **1 世界單位 = 1 tile，PPU = 一個 tile 的像素數**。16×16 的 tile 就 `PPU = 16`，於是魔法陣 JSON 裡的半徑直接讀作 tile 數——作者調 `size: 3.0` 時心裡想的是「三格寬」，不必換算。

Haskell 宿主要**現成的螢幕映射**（原點、PPU、y 翻轉、平移、游標定錨縮放、視窗 resize）可以照抄 `app/App/Render/Flat.hs` 的 `screenOf`／`panBy`／`zoomAt`／`resizeTo`——約 50 行純函數，不依賴 renderer。它**刻意不在 boundary 裡**（[ADR-0008](adr/adr-0008-dimension-agnostic-3d-first.md)：投影屬外殼，螢幕映射是呈現選擇，不凍結），所以照抄時請一併帶走它的性質律，那才是難的部分：

- **pan 是線性的**：`screenOf (panBy d fv) p == screenOf fv p + d`，零位移是恆等。
- **zoom 有定點**：游標底下的世界點在縮放後仍在游標底下——**精確**成立，不是近似。做法是原點與縮放係數同乘一個因子，並且**從 clamp 之後的 PPU 反推**該因子，否則縮到上下限時畫面會從游標底下滑走。

`app/App/Render/Flat.hs` 的 `buildFlatQuads` 則**不要**照抄：它輸出 raylib dynamic mesh 專用的 `QuadBatch`，是貨真價實的引擎專屬品。

#### 3. 像素對齊：放大整個畫面，不要 round 每一顆

位置是 `Float`。逐顆 `round` 到像素格會讓慢速粒子**抖動**（連續移動被量化成一格一格的跳動，而且不同粒子在不同幀跳，看起來像雜訊）。

標準解法是**別碰粒子座標**：把整個場景畫到一張**原生解析度的 render target**（例如 320×180），再**整數倍**放大（nearest-neighbour）貼到視窗上。粒子與美術素材自然落在同一格上，而且魔法的所有次像素運動仍然存在於低解析畫布裡，只是被統一量化了一次。

#### 4. 顏色：連續 ramp ↔ limited palette 的張力

`color` 是**沿顏色曲線依 `life` 內插出來的連續漸層**（`0xRRGGBBAA`，見 [§2.1](#21-六條欄位)）——一顆粒子從生到死會掃過整條曲線。像素風通常是受限調色盤。兩條路：

- **後處理量化**：在 shader 裡把最終畫面查最近色映回調色盤。整個畫面一致，美術素材與粒子同一套規則。
- **端點對齊**：把屬性的 ramp 兩端設計成剛好命中調色盤裡的顏色，中間的內插值仍然是連續的，但視覺上只會在少數幾階之間走。

這是美術方向的決定，庫不插手；文件只負責讓你在做完之後才發現這個張力之前先知道它存在。

#### 5. 貼圖：`rbShape` 是 tag，不是資產

`rbShape`（C 側 `batch_info[+3]`）是四個無參數的碼：`square`／`soft-dot`／`ring`／`spark`，由魔法陣的 `style` 符文指定。**它不帶任何資產**——demo 用 64×64 程序生成的 alpha 貼圖是 demo 的選擇，你的宿主把它換成自己的 8×8 像素圖完全合法，也是像素風應該做的事。不認得的碼照 `square` 畫即可。

RGB 一律來自頂點色（貼圖只提供 alpha 形狀），所以同一張 8×8 圖能吃下所有屬性的顏色。

---

## 4. 路線 B：C／C++ 宿主

### 4.1 建置

```
cabal build particle-magic-ffi
```

產物（Windows，`standalone` 內嵌 GHC RTS，約 46 MB）：

```
dist-newstyle/build/x86_64-windows/ghc-9.14.1/particle-magic-0.1.0.0/f/
  particle-magic-ffi/build/particle-magic-ffi/
    particle-magic-ffi.dll        <- 執行期需要
    particle-magic-ffi.dll.a      <- 連結期需要（匯入庫）
```

Linux／macOS 為 `libparticle-magic-ffi.so` / `.dylib`。

```
gcc -Iinclude your_host.c path/to/particle-magic-ffi.dll.a -o game.exe
```

（機器上沒有獨立 gcc 也行：ghcup 隨附的 `clang` 等價，spec 0009 的驗收就是用它做的。）

### 4.2 最小完整迴圈

```c
#include "particle_magic.h"

#define FIXED_DT_F (1.0f / 60.0f)                /* pm_advance_ex 收的 */
#define FIXED_DT   ((double)FIXED_DT_F)          /* pm_plan_steps 規劃用的 */
#define MAX_STEPS_PER_FRAME 8                    /* 死亡螺旋防護，見 §2.4 */

static float *px, *py, *pz, *sz, *lf;
static uint32_t *col;
static int    info[8 * PM_BATCH_INFO_STRIDE];

int main(void)
{
    char  err[256];
    const float pos[3]    = {0, 0, 0};
    const float facing[3] = {0, 0, 1};
    int    cap;
    double acc = 0.0;

    pm_init();                                   /* 冪等，啟動 GHC RTS */

    if (pm_abi_version() != PM_ABI_VERSION) {    /* header 與 .dll 是同一代嗎 */
        return 1;
    }

    /* 六條欄的長度來自執行期查詢，不是 header 的凍結常數（見 §2.5） */
    cap = pm_max_particles();
    px = malloc(cap * sizeof(float));            /* ... 六條都一樣 */
    /* ... py, pz, sz, lf, col ... */

    PmSpell *s = pm_cast(json_text, pos, facing, 42, err, sizeof err);
    if (!s) {                                    /* NULL = 失敗，原因在 err */
        fprintf(stderr, "%s\n", err);
        return 1;
    }

    while (!pm_is_finished(s)) {
        int steps;

        /* 幀時間交給規劃器，它決定這一幀要走幾個固定步（最多 8 個） */
        pm_plan_steps(FIXED_DT, MAX_STEPS_PER_FRAME, seconds_since_last_frame,
                      acc, &steps, &acc);
        while (steps-- > 0) {
            pm_advance_ex(s, FIXED_DT_F);
        }

        int n = pm_observe(s, px, py, pz, sz, lf, col,
                           cap, info, 8);
        if (n < 0) { break; }                    /* PM_ERR_CAPACITY */

        for (int i = 0; i < n; i++) {
            int offset = info[i * PM_BATCH_INFO_STRIDE + 0];
            int count  = info[i * PM_BATCH_INFO_STRIDE + 1];
            int blend  = info[i * PM_BATCH_INFO_STRIDE + 2];
            /* 設好混合狀態，把 [offset, offset+count) 這一段餵進頂點緩衝 */
            draw_your_quads(px + offset, py + offset, pz + offset,
                            sz + offset, lf + offset, col + offset,
                            count, blend);
        }
    }

    pm_free(s);
    pm_shutdown();
    return 0;
}
```

`examples/c/main.c` 是這段的完整可執行版（印出逐幀摘要而非畫圖，含六條欄的配置與釋放、以及每個回傳碼的檢查）。兩邊必須同步：`test/ExampleLoopSpec.hs` 守著這一點。

### 4.3 錯誤處理

| 情況 | 回傳 |
|---|---|
| `pm_cast` 失敗 | `NULL`，人類可讀的 UTF-8 原因寫進 `err_buf`（保證 NUL 結尾、超長安全截斷；`err_buf` 可為 `NULL`） |
| 想知道**為什麼**失敗 | 改用 `pm_cast_ex(..., &spell)`：回 `PM_OK` / `PM_ERR_JSON`（JSON 不合法或符文 tag 不認識）/ `PM_ERR_BUDGET`（合法，但要求的粒子數超過上限） |
| `pm_observe` 空間不足 | `PM_ERR_CAPACITY`，**一個位元組都不寫**——不會有半更新的幀 |
| `pm_project` / `pm_depth_order` 參數不合法 | `PM_ERR_ARGS`（`NULL` 指標、負長度、未知 plane），同樣**一個位元組都不寫** |
| **呼叫順序錯了** | `PM_ERR_STATE`（−7）：`pm_init()` 之前就呼叫、`pm_shutdown()` 之後再初始化、重複帶設定初始化、或設定在當前平台無法生效。是**你的**呼叫順序問題，不是法術的問題（見 §4.4） |
| **庫內部出錯** | `PM_ERR_INTERNAL`（−6）：例外防火牆攔到了庫自己的失敗（記憶體耗盡、缺陷、沒人寫到的情況）。永遠不是你這次呼叫的錯，**不必重試**，你的 process 也不受影響——但值得回報一個 bug。良好行為的呼叫永遠不會看到它 |
| `pm_scene_cast` / `pm_scene_cast_many` 失敗 | 同樣四碼加一：`PM_ERR_JSON` / `PM_ERR_BUDGET`（單張陣自己就編不出來）/ **`PM_ERR_QUOTA`**（編得出來，但場景放不下——見 §4.6）/ `PM_ERR_ARGS`（`NULL` 場景、`NULL out_id`、負 count）。四種都寫人類可讀原因進 `err_buf`，且**場景完全未變** |

錯誤訊息與 demo HUD 上顯示的是同一句（共用 `Magic.Codec.renderLoadError`），含 JSON 路徑，例如
`spell JSON error: Error in $.circle.bridge: unknown rune tag "bogus"`。

### 4.4 生命週期規則

- `pm_init()` 冪等，可以被多個子系統各叫一次。想指定 RTS 設定就改用 `pm_init_ex()`（見 §4.4.1）；兩者擇一，只需要成功一次。
- **初始化之前呼叫任何符號都不會殺掉你的 process**。未初始化（以及 `pm_shutdown()` 之後）每個符號都回哨兵值：回計數／錯誤碼的回 `PM_ERR_STATE`（−7），`pm_cast`／`pm_scene_new` 回 `NULL`（前者另把原因寫進 `err_buf`），`pm_age` 回 `-7.0`，`pm_occupancy_mask` 回 `0`，五個 `void` 的安靜返回。
- 唯一的例外是 **`pm_abi_version()`**：它由 C 層直接回答，**任何狀態下都安全**，所以 startup 的世代比對可以擺在 `pm_init*()` 之前。
- **執行緒模型見 §4.4.2**（ADR-022 D4 修訂 ADR-0011 D4）。摘要：不同 handle 隨便併發；同一個 handle 的多次推進或多次施法**不丟更新**；順序不保證；`pm_free` 與同 handle 的其他呼叫要你自己排。初始化與關閉本身是原子的：兩個執行緒同時 `pm_init_ex()` 只有一個生效，另一個回 `PM_ERR_STATE`，不會崩潰。
- `pm_free(NULL)` 是 no-op。**重複 free、free 過再用、亂造一個 handle 都不再是 UB**：handle 帶世代標籤,庫認得出來並回 `PM_ERR_ARGS`,不會讀已釋放的記憶體、也不會終止你的 process(ADR-022 D3 修訂 ADR-0011 D4)。七個沒有錯誤碼通道的凍結符號改以中性值兌現同一條保證——`pm_advance`／`pm_free`／`pm_scene_free`／`pm_scene_dismiss`／`pm_scene_advance` 無操作,`pm_age` 回 `0.0`,`pm_occupancy_mask` 回 `0`。唯一抓不到的是「偽造的值恰好等於一個現存的合法 handle」,那是任何 handle 方案的共同上限。
- handle **不是可以解參考的指標**,是一個不透明的識別字(值恆為奇數,永遠不會是對齊的堆積位址)。只把它原樣傳回庫裡。
- **`pm_shutdown()` 是單向門**：之後這個 process 不能再使用本庫——`pm_init_ex()` 回 `PM_ERR_STATE`、`pm_init()` 是無操作、其餘符號一律回哨兵。它**不再殺掉你的 process**：以前 `pm_shutdown()` 之後再 `pm_init()`，GHC 的 RTS 會印一行 `reinitializing the RTS after shutdown is not currently supported` 然後直接讓宿主死掉。現在那個拒絕是一個錯誤碼。長駐型宿主（尤其 Unity Editor）**乾脆永遠不要呼叫它**。
- `pm_shutdown()` 呼叫兩次是無操作，也不會出現 RTS 的 `too many hs_exit()s` 警告。Windows 與 Linux 的關閉語意**完全一致**，因為答案來自庫自己的狀態機而不是 RTS。
- 一個 process 只能有一份 GHC RTS——不要把兩個 GHC 產生的共享庫連進同一個宿主。
- **`GHCRTS` 環境變數對本庫無效**。庫以 `RtsOptsIgnoreAll` 啟動 RTS，所以環境變數既不能蓋掉宿主透過 `pm_init_ex()` 給的設定，也不能用一個非 safe 的選項把宿主 process 殺掉（實測 `GHCRTS=-A128m` 對舊版的 `pm_init()` 就是這個下場）。要調 RTS 只有 `pm_init_ex()` 一條路。

### 4.4.1 執行期設定：`pm_init_ex()`（host-runtime F003 新增）

**RTS 是宿主的**（ADR-022 D1）。庫不設定就保守——單 capability、預設 GC、不收統計——也不會自己開 OS 執行緒。要別的就自己說：

```c
PmConfig cfg = {0};
cfg.size          = sizeof cfg;
cfg.capabilities  = 4;                    /* 0 = 依硬體；通常你要的是 2..4 */
cfg.nursery_bytes = 64u * 1024u * 1024u;  /* 0 = RTS 預設的 4 MiB */
cfg.gc_mode       = PM_GC_NONMOVING;      /* 或 PM_GC_DEFAULT */
cfg.stats         = PM_STATS_ON;          /* 想要 GC 數字就只能在這裡表態 */

int rc = pm_init_ex(&cfg);
if (rc == PM_ERR_ARGS) { /* 設定超出範圍，什麼都沒啟動 */ }
```

`PmConfig` 以 `size` 欄開頭：把整個結構清零、填 `sizeof(PmConfig)`，之後的世代加欄位也不會弄壞舊宿主。反過來，**本庫不認得的 `size` 一律拒收**（`PM_ERR_ARGS`）而不是忽略多出來的欄位——「不靜默忽略任何無法生效的設定」是這條契約的硬規則。

| 欄位 | 合法值 | 超出範圍時 |
|---|---|---|
| `size` | `sizeof(PmConfig)`（本世代為 24） | `PM_ERR_ARGS` |
| `capabilities` | `0`（依硬體）或 `1..PM_MAX_CAPABILITIES`（256） | `PM_ERR_ARGS` |
| `nursery_bytes` | `0`（RTS 預設）或 `PM_NURSERY_MIN_BYTES`（8192）`..PM_NURSERY_MAX_BYTES`（1 GiB） | `PM_ERR_ARGS` |
| `gc_mode` | `PM_GC_DEFAULT` / `PM_GC_NONMOVING` | `PM_ERR_ARGS` |
| `stats` | `PM_STATS_OFF` / `PM_STATS_ON` | `PM_ERR_ARGS` |

每一條都是 RTS 自己會用「終止整個 process」來執行的界線（`-N0`、`-A0`、壞掉的選項字串都是當場死），所以庫在碰 RTS 之前就先擋下來，而且**選項字串由庫自己生成**，不接受宿主的任何自由文字。

回傳只有三種：

| 回傳 | 意思 |
|---|---|
| `PM_OK` | 四項全部生效 |
| `PM_ERR_ARGS` | 設定超出上表，**什麼都沒啟動**，可以改好再呼叫一次 |
| `PM_ERR_STATE` | 兩種語氣，見下 |

`PM_ERR_STATE` 的兩種語氣很好分——後者只可能發生在**你自己的第一次** `pm_init_ex()`：

1. **呼叫順序錯**：已經初始化過了，或在 `pm_shutdown()` 之後。**什麼都沒發生**，這次的設定沒有生效。
2. **庫已就緒，但部分設定在這個 process 無法生效**：RTS 在你呼叫之前就已經被**宿主自己**啟動了（Haskell 宿主，或你自己先呼叫過 `hs_init`）。capability 數仍然透過 RTS 的執行期 API 生效，nursery、GC 模式與統計旗標則無法套用。庫可以正常使用。

逐平台生效表（2026-08-20 對出貨產物實測；macOS 尚未實測，依 Linux 路徑推斷）：

| 平台 | `capabilities` | `nursery_bytes` | `gc_mode` | `stats` |
|---|---|---|---|---|
| Windows x86_64（standalone DLL） | 生效 | 生效 | 生效 | 生效 |
| Linux x86_64（`.so`） | 生效 | 生效 | 生效 | 生效 |
| macOS（`.dylib`，未實測） | 預期生效 | 預期生效 | 預期生效 | 預期生效 |
| 任一平台，但 RTS 已由宿主啟動 | 生效 | **不生效** | **不生效** | **不生效** |

最後一列就是上面第 2 種語氣。Windows 的 standalone DLL **並不會**在 `DllMain` 先幫你啟動 RTS（這一點以前的文件推測錯了，已實測更正），所以純 C／C++／Unity 宿主拿到的是前兩列。

**capability 數怎麼選**。核心的取樣器在單一視窗達到 **8192** 列以上時會切到分片路徑；`capabilities = 1` 時那條路徑付了分片與串接的成本卻拿不到任何加速。所以：

- 只跑小陣（< 8192 粒）：`capabilities = 1` 與多 capability 沒有差別。
- 會跑大陣：`2..4`。
- **通常不要填 `0`**（＝整台機器的核心數）：粒子取樣會跟引擎自己的 job system 搶時間片。

輸出與 capability 數無關、逐位元相同（ADR-0017），所以這純粹是成本取捨，不是正確性問題。

**RTS 統計**。統計旗標**無法在初始化之後打開**，所以想要進程層級的 GC 次數與暫停時間，就必須在 `pm_init_ex()` 的 `stats` 欄表態。沒表態時 `getRTSStatsEnabled()` 為假，那些數字會被回報為「**不可用**」而不是零——RTS 自己在統計關閉時回的暫停時間就是 `0`，跟「這一段真的沒有 GC 暫停」長得一模一樣，只有旗標本身是誠實的判準。

### 4.4.2 執行緒模型（host-runtime F004 明文化）

以前這裡只寫「handle 歸單一執行緒所有」一句。那句話對你沒有用：它沒說不同 handle 行不行，也沒說違反了會發生什麼。現在的合約是兩張清單。

先三句承諾：

- 庫**永遠不會自己開 OS 執行緒**。每一行都跑在你呼叫進來的那條執行緒上。
- **每幀路徑不取任何鎖**（推進、觀測、任何查詢）。你一幀呼叫一次的東西不會被庫內部的任何事情擋住。
- 內部失敗**只毒化那一個 handle**：它從此每次呼叫都回 `PM_ERR_INTERNAL`（沒有錯誤碼通道的符號回自己的哨兵值），其他 handle 與你的 process 完全不受影響。

**可以直接併發（庫負責）**

| 操作 | 保證 |
|---|---|
| 不同 handle 的任何操作 | 無限制 |
| 同一個 handle 的多次 `pm_advance` | **不丟更新**——N 次併發推進恰好推進 N 步，不會是 N−1 |
| 同一個場景的多次 `pm_scene_cast`／`pm_scene_cast_many`／`pm_scene_dismiss` | **不丟更新**，且配額**一個法術只算一次**。往只剩一個名額的場景併發施法兩次，結果一定是一個 `PM_OK` 加一個 `PM_ERR_QUOTA` |
| 推進與觀測／查詢併發 | 讀到的一定是推進**前**或推進**後**的完整快照，不會半新半舊 |
| `pm_abi_version`／`pm_max_particles`／`pm_project`／`pm_depth_order`／`pm_plan_steps` | 無狀態，任何執行緒任何時候 |

**必須由你自己序列化（庫看不到）**

| 操作 | 為什麼 |
|---|---|
| `pm_free`／`pm_scene_free` 與**同一個** handle 的任何其他呼叫 | 釋放的瞬間 handle 就失效；併發者會落在其中一側——要嘛正常執行，要嘛回 `PM_ERR_ARGS`。兩側都不崩潰，但拿到哪一個不保證 |
| `pm_init`／`pm_init_ex`／`pm_shutdown` 與任何呼叫 | 那是執行期的生命週期，不是某個 handle 的 |
| 兩次寫進**同一組**宿主陣列的觀測 | 那是你的記憶體，庫不知道兩次呼叫共用它 |
| 把 handle 交給另一條執行緒 | 要透過佇列、鎖或 job 相依邊發布——跟任何 C API 一樣。真正的同步原語才帶記憶體屏障 |
| 需要**成對**的推進與觀測（「這一幀的畫面要對應這一幀的推進」） | 兩個呼叫各自安全，但相對順序不保證 |

**不保證的到底是什麼**：同一個 handle 上併發操作的**順序**，僅此而已，沒有任何一個會被丟掉。對推進來說這個區別沒有可觀測後果——每一步都是「在前一個值上加同一個 `dt`」，最終狀態與交錯順序無關；對施法來說，併發拿到的 `SpellId` 誰先誰後不保證。

成本：原子讀改寫的固定成本是個位數奈秒（實測每次推進 +6.5 ns，約 60 fps 幀預算的 4×10⁻⁵ %）。這是**不付鎖的成本**，不是不付成本。

### 4.5 2D 宿主：投影與深度排序（0011 新增）

Haskell 宿主一直有 `Magic.Projection`；0011 之後 C 宿主也有同一份純數學，**不必自己重寫一份**——重寫的風險不是難，是「排出來跟 Haskell 路徑不一樣」。

```c
int cap = pm_max_particles();
float *sx = malloc(cap*sizeof(float)), *sy = ..., *depth = ...;
int   *order = malloc(cap*sizeof(int));

int n = pm_observe(spell, px, py, pz, size, life, color, cap, info, 8);
int total = 0;
for (int b = 0; b < n; b++) total += info[b*PM_BATCH_INFO_STRIDE + 1];

/* 丟一軸：側視 (x, y)、俯視 (x, z)。depth 越大越遠。 */
pm_project(PM_PLANE_SIDE_XY, px, py, pz, total, sx, sy, depth);

/* painter 置換：由遠而近，等深保持輸入序（＝決定性）。 */
pm_depth_order(PM_PLANE_SIDE_XY, px, py, pz, total, order);
for (int k = 0; k < total; k++) draw_quad(sx[order[k]], sy[order[k]], /* ... */);
```

三點值得記住：

1. **不吃 handle**：投影是位置的函數，跟法術狀態無關。你可以投任何來源的位置欄——`pm_observe` 的輸出、其中一段批次，或你自己的粒子。
2. **螢幕座標仍然是你的事**：庫只做「丟軸＋深度」，原點、pixels-per-unit、y 軸方向都由你決定（`Magic.Projection` 對 Haskell 宿主也是同一條線）。怎麼決定——包含 `PM_PLANE_TOP_XZ` 與 `casterFacing` 那個會靜默塌掉的組合——見 [§3.3](#33-2d像素風宿主食譜)，那一節不分語言。
3. **加法批次不需要排序**（加法可交換），只有 alpha 批次需要。想只排一段就把該段的起點指標與長度傳進去即可。

跨界等價律（`test/Acceptance11Spec.hs`）保證這條路徑與 Haskell 的 `orthographic`／`depthOrder` 逐位元相同，9 個範例陣 × 2 個平面 × 120 幀。

### 4.6 一次好幾張陣:場景（0018 新增）

§4.2 的迴圈驅動**一張**陣。要同時有好幾張,不必自己開一個 `PmSpell*` 陣列記帳——`Magic.Scene`(§3.2)整個上了 C ABI:

```c
int cap = 8192;                       /* 這個場景所有法術加起來的粒子上限 */
PmScene *sc = pm_scene_new(cap);
char err[512];
int  id;

if (pm_scene_cast(sc, json, pos, facing, 42, err, sizeof err, &id) != PM_OK)
    fprintf(stderr, "%s\n", err);     /* PM_ERR_QUOTA 時可以先 dismiss 再重試 */

for (;;) {
    pm_scene_advance(sc, 1.0f/60.0f); /* 推進全部,已結束的自動移除＝配額回收 */
    int n = pm_scene_observe(sc, px, py, pz, size, life, color,
                             cap, info, MY_MAX_BATCHES);
    /* 六欄與 batch_info 的佈局、PM_BATCH_INFO_STRIDE、all-or-nothing 全部同 pm_observe */
}
pm_scene_free(sc);
```

十個進入點與 §3.2 那張表逐項對應:`pm_scene_new`／`_free`／`_cast`／`_cast_many`／`_dismiss`／`_advance`／`_observe`／`_budget`／`_count`／`_spells`。完整可跑的軌跡見 [`examples/c/scene.c`](../examples/c/scene.c)（兩張共存 → 第三張被配額拒 → 一張自然結束後配額釋放 → 第三張成功）。

四件與單張陣不同、而且做錯是**靜默**的事:

| | 說明 |
|---|---|
| **六欄開多大** | 用你傳給 `pm_scene_new` 的 `global_cap`,**不要**用 `pm_max_particles()`——後者界定的是**單一法術**。搞反的症狀是第二張陣進場後 `pm_scene_observe` 開始回 `PM_ERR_CAPACITY`,而且照慣例整幀不寫,看起來像閃爍不像錯誤 |
| **新錯誤碼 `PM_ERR_QUOTA`（−5）** | 法術編得起來,只是場景滿了——這是唯一值得**反應**（先 `pm_scene_dismiss` 再重試）而不只是記 log 的失敗。被拒的那一次**場景一個位元都沒變**,`pm_scene_count`／`_spells`／`_budget` 三者皆與拒收前相同 |
| **場景獨佔其法術** | 進了場景的法術**沒有** `PmSpell*`;不能丟給 `pm_free`,也不能把既有的 `PmSpell*` 搬進場景。每次施法二選一 |
| **一個 scene 一個執行緒** | 與 `PmSpell*` 同一條紀律,庫內仍然無鎖 |

`SpellId` 遞增不重用,所以陳舊的 id 是**惰性**而非歧義:`pm_scene_dismiss` 對未知／已結束的 id 是 no-op,宿主不必先查法術還活著沒有,也不需要 generation counter。

**`batch_info` 不會告訴你某個 batch 屬於哪一張陣**——`observeScene` 自己也不知道,C 面刻意不比 Haskell 面多知道一件事。真有需求時的做法（先在 boundary 加 `observeSceneBy`,C 面再加一個平行 out 陣列,**不動 `PM_BATCH_INFO_STRIDE`**）記在 func-spec 0018 §8-1。

跨界等價律（`test/Acceptance18Spec.hs`）:對生成的操作序列,每一步之後 `pm_scene_observe` 與 `observeScene` 逐位元相同,收碼分類與 `castInto` 的 `Either CastRefusal` 一致,`pm_scene_budget` 與 `sceneBudget` 相同。

### 4.7 這道法術佔哪裡（0025 新增）

§3.1.1 的空間摘要整套上了 C ABI，7 個純增補進入點，`PM_ABI_VERSION` 仍是 **1**：

```c
float lo[3], hi[3];
pm_spell_bounds(spell, lo, hi);            /* 整道法術一輩子的世界 AABB */

float c[3], axes[9], half[3];              /* axes 是 3x3 列主序：U, V, 法線 */
pm_spell_box(spell, c, axes, half);        /* 同上，但是有向盒——緊得多 */

int n = pm_emitter_count(spell);
pm_emitter_box(spell, 0, c, axes, half);   /* 單一發射器「目前」的盒 */

int counts[27];
pm_occupancy(spell, PM_OCCUPANCY_DIM_DEFAULT, counts, 27);   /* 3x3x3 計數 */
uint32_t mask = pm_occupancy_mask(spell);  /* 同一件事，一個字，零配置 */

/* 場景裡的某一道：pm_scene_spells 給 id，這裡給界 */
pm_scene_spell_bounds(scene, id, lo, hi);
```

broad phase 因此是一行：兩道法術的 mask 做 AND，非零才需要細算。

要記住的三件事與 §3.1.1 相同（有向盒比 AABB 緊、兩種時窗刻意不同、格網的框全程固定）。C 面另外兩點：

- `pm_occupancy` 的 `capacity` 不足時回 `PM_ERR_CAPACITY` 且**一個位元都不寫**，與 `pm_observe` 同一條 all-or-nothing 規則；`dim` ≤ 0 是 `PM_ERR_ARGS`。
- `pm_occupancy_mask` 對 `NULL` handle 回 0，位元 27..31 恆為 0。

跨界等價律（`test/FFISpaceSpec.hs`）：每個進入點與對應的 `Magic.Interface` 函數逐位元相同，13 個範例陣 × 3 種維度。

### 4.8 MSVC 連結（Visual Studio 宿主）

§4.1 給的 `particle-magic-ffi.dll.a` 是 **MinGW** 格式的匯入庫，`cl.exe` 不吃它。發布產物因此另外附一份 COFF 匯入庫 `particle-magic-ffi.lib`（見 [release.md](release.md) §6），MSVC 宿主連它：

```
cl.exe /nologo /W3 /I <drop> your_host.c <drop>\particle-magic-ffi.lib /Fe:game.exe
```

`<drop>` 就是解壓出來的那個資料夾——標頭與匯入庫都在裡面，**不需要指向這個 repo 的任何路徑，也不需要機器上有 GHC**。執行期把 `particle-magic-ffi.dll` 放在 exe 旁邊（或任何 `LoadLibrary` 找得到的地方）即可，那份 DLL 是 standalone 的，RTS 在裡面。

驗過的結果：這樣連出來的 exe，`dumpbin /dependents` 只有 **`particle-magic-ffi.dll` 與 `KERNEL32.dll`** 兩個匯入，跑完 120 幀的完整生命週期。`packaging/smoke-msvc.ps1` 就是把上面這段做一遍，退出碼即結論。

**自己產一份匯入庫**（不想等發布包，或想從自己的建置產出來）：權威輸入是 repo 根目錄的 `particle-magic-ffi.def`，也就是 DLL 連結時用的同一份匯出清單，兩條路都可以：

```
lib.exe /nologo /def:particle-magic-ffi.def /machine:x64 /out:particle-magic-ffi.lib
llvm-dlltool -m i386:x86-64 -d particle-magic-ffi.def -D particle-magic-ffi.dll -l particle-magic-ffi.lib
```

第二條用的是 ghcup 隨附的 `llvm-dlltool`，機器上沒有 Visual Studio 也能產；兩種產出都實測可被 `cl.exe` 連結。`packaging/pack.ps1` 先找 `lib.exe`（透過 `vswhere`），找不到就退回 `llvm-dlltool`。

C++ 宿主沒有額外步驟——標頭已經包在 `extern "C"` 裡（§4.3 的錯誤碼與 §4.4 的生命週期規則原封不動適用）。

### 4.9 macOS：`@rpath` 與雙架構

> **本節未經驗證。** 建置設定與打包腳本的 macOS 分支已經寫好，但本輪沒有 macOS 機器產出或檢查過任何一份 `.dylib`；發布清單（[release.md](release.md) §6）的兩個 macOS 平台項因此標 `verified: false`。真的要用，請自己先跑一次完整生命週期再上線。

Cabal **不會**替 foreign library 設 `install_name`，預設會把建置時的絕對路徑寫進 `.dylib`——檔案一搬走，宿主就載不到。本專案的 cabal 檔因此在 `if os(darwin)` 下自己下：

```
-optl-Wl,-install_name,@rpath/libparticle-magic-ffi.dylib
```

意思是「我的名字由載入我的人決定」。宿主端相對應地給自己一條 rpath：

```
clang -I<drop> your_host.c <drop>/libparticle-magic-ffi.dylib \
      -Wl,-rpath,@executable_path -o game
```

`@executable_path` 表示「exe 旁邊」；把 `.dylib` 和 exe 放同一層就成立。App bundle 常見的寫法是 `-Wl,-rpath,@executable_path/../Frameworks`。用 `otool -L game` 可以確認宿主記下的是 `@rpath/libparticle-magic-ffi.dylib` 而不是誰的家目錄。

**雙架構**：x86_64 與 arm64 是兩次建置，用 `lipo -create` 併成一份 universal `.dylib`。`packaging/pack.sh` 在 macOS 上接受 `--fat-with <另一個架構的 dylib>` 走這一步。

**Linux 宿主不需要這一節**，但值得知道對應的機制：Linux 產物是 `.so` 加上它整包共享物件閉包放同一層，`.so` 的搜尋路徑是 `$ORIGIN`（＝「我自己所在的資料夾」）。宿主照 §4.1 連結即可，把整個資料夾一起搬走就會動；`packaging/pack.sh --verify` 在乾淨環境下驗過這件事。


---

## 5. 路線 C：Unity（C#）

Unity 走的就是 §4 的 C ABI，只是隔著 P/Invoke。

**0011 起這一節的程式碼是真檔案，不再是片段**：

| 檔案 | 是什麼 |
|---|---|
| [`bindings/csharp/ParticleMagic.cs`](../bindings/csharp/ParticleMagic.cs) | 參考綁定：30 個 `DllImport`（0011 的 13 個 ＋ 0018 的場景 10 個 ＋ 0025 的空間 7 個）、全部常數、顏色拆包與 Z 翻轉助手。**不依賴 Unity**，Godot C#／純 .NET 照用 |
| [`examples/unity/SpellRenderer.cs`](../examples/unity/SpellRenderer.cs) | 一個真的會畫東西的 `MonoBehaviour`：固定時步、緩衝重用、Z 翻轉、alpha 批次用 `pm_depth_order` 排序 |
| [`examples/unity/PmSmoke.cs`](../examples/unity/PmSmoke.cs) | 一行指令跑完整個 smoke（`unity run … -executeMethod PmSmoke.Run`），驗 marshaller、投影、排序與 Mesh |
| [`examples/unity/README.md`](../examples/unity/README.md) | 放置步驟、材質設定、預期畫面、smoke 指令與人眼 checklist |

`test/BindingContractSpec.hs` 斷言那份 `.cs` 的進入點與常數集合**雙向等於** header——header 加了東西而綁定沒跟上，`cabal test` 就紅。整套在 Unity 6000.5.7f1 實測通過（27 PASS／0 FAIL，見 [0011 §9.3](spec/func-0011-host-integration-surface.md)）。下面幾節解釋的是「為什麼那樣寫」。

### 5.1 放置 DLL

```
Assets/Plugins/x86_64/particle-magic-ffi.dll
```

在 Inspector 裡把它設為 **Standalone / x86_64**。Editor 也要勾（不然編輯器裡跑不動）。

### 5.2 P/Invoke 宣告

整份宣告在 [`bindings/csharp/ParticleMagic.cs`](../bindings/csharp/ParticleMagic.cs)，貼進 `Assets/Scripts/` 即可。要點只有三個：

```csharp
[DllImport("particle-magic-ffi", CallingConvention = CallingConvention.Cdecl)]
public static extern int pm_observe(IntPtr spell,
                                    float[] posX, float[] posY, float[] posZ,
                                    float[] size, float[] life, uint[] color,
                                    int capacity, int[] batchInfo, int maxBatches);
```

1. **`CallingConvention.Cdecl`**，每一個都要寫。
2. **JSON 傳 UTF-8 位元組並自行補 `\0`**（`byte[]`），不要傳 `string`——編碼會隨 scripting backend 變。
3. **`float[]` / `uint[]` / `int[]` 都是 blittable**：marshaller 會釘住（pin）原陣列直接傳指標，不逐元素複製，所以每幀 `pm_observe` 只有一次跨界呼叫。代價是**陣列必須重複使用**（欄位而非區域變數），否則每幀都在製造 GC 垃圾。

緩衝長度用 `Pm.pm_max_particles()`（見 [§2.5](#25-六條陣列要開多大)），不要用 `Pm.MaxParticles` 常數。

### 5.3 RTS 生命週期（最容易踩的一個坑）

```csharp
[RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
static void BootParticleMagic()
{
    Pm.pm_init();
    if (Pm.pm_abi_version() != Pm.AbiVersion)
        Debug.LogError("particle-magic ABI mismatch");
}
```

**絕對不要在 `OnDestroy` / `OnApplicationQuit` 呼叫 `pm_shutdown()`。**

原因見 §4.4：GHC 的 RTS 停掉之後就無法在同一個 process 重啟，所以 `pm_shutdown()` 是**單向門**——之後這個 process 的每個符號都回 `PM_ERR_STATE`（或它自己的哨兵值）。而 Unity Editor 在停止播放時**不會卸載 native plugin**——下一次按 Play 還是同一個 process。舊版的症狀是「第一次跑正常、第二次直接讓 Editor 掛掉」；現在不會掛了，但庫也一樣不能再用，所以規則沒變：別呼叫它。

想指定 capability 數或 GC 模式就把 `Pm.pm_init()` 換成 `Pm.pm_init_ex(ref cfg)`，見 §4.4.1。`Pm.pm_abi_version()` 在初始化之前也安全，所以世代比對擺在最前面也可以。

正確做法：`pm_init()` 一次，之後就讓它活著。真正的清理只有 `pm_free()`（每個法術一次），這個一定要做。

```csharp
void OnDestroy()
{
    if (spell != IntPtr.Zero) { Pm.pm_free(spell); spell = IntPtr.Zero; }
    // 不呼叫 pm_shutdown()
}
```

### 5.4 每幀

完整版見 [`examples/unity/SpellRenderer.cs`](../examples/unity/SpellRenderer.cs)（含 Mesh 組裝與批次排序）。骨架就是這四步：

```csharp
void Update()
{
    if (spell == IntPtr.Zero) return;

    // 1. 固定時步：步數交給庫的規劃器算（雙精度累加器＋單幀上限，見 §2.4）
    int steps;
    double nextAcc;                                         // accumulator 欄位必須是 double
    if (Pm.pm_plan_steps(FixedDtSeconds, MaxStepsPerFrame, Time.deltaTime,
                         accumulator, out steps, out nextAcc) == Pm.Ok)
    {
        accumulator = nextAcc;                              // 被拒時兩個 out 都沒寫，累加器維持原值
        for (int i = 0; i < steps; i++) Pm.pm_advance_ex(spell, FixedDt);
    }

    // 2. 一幀取樣一次，寫進重複使用的六條欄（capacity 來自 pm_max_particles()）
    int n = Pm.pm_observe(spell, px, py, pz, sz, lf, col, capacity, info, MaxBatches);
    if (n < 0) { Debug.LogWarning("pm_observe: capacity"); return; }   // 什麼都沒寫，不要畫舊資料

    // 3. 一批一個 draw：offset / count / blend 都在 info 裡
    for (int b = 0; b < n; b++) BuildMesh(info[b * Pm.BatchInfoStride + 0],
                                          info[b * Pm.BatchInfoStride + 1],
                                          info[b * Pm.BatchInfoStride + 2]);

    // 4. 結束就還手把
    if (Pm.pm_is_finished(spell) != 0) { Pm.pm_free(spell); spell = IntPtr.Zero; }
}
```

### 5.5 座標系轉換

庫是**右手系**（X 右、Y 上、**+Z 朝觀者**），Unity 是**左手系**（+Z 進畫面）。轉換就是**翻 Z**——進去的輸入翻一次，出來的位置翻一次（綁定裡的 `PmConvert.ToPm` / `PmConvert.FlipZ`，或直接在組頂點時寫 `-pz[i]`）。

翻不翻不會崩潰，只有一個症狀會露餡：**`vortex` 力場的旋轉方向會反過來**（外積是有手性的）。純解析式的法術（沒有 `fields`）看起來會完全一樣，所以這個 bug 很容易在加上力場之後才被發現——寧可一開始就翻對。

### 5.6 混合模式對照

| `batch_info[+2]` | 意義 | Unity 材質 |
|---|---|---|
| `PM_BLEND_ALPHA` (0) | 一般 alpha 混合 | `Blend SrcAlpha OneMinusSrcAlpha`，`ZWrite Off` |
| `PM_BLEND_ADDITIVE` (1) | 加法混合（火、雷這類發光體） | `Blend SrcAlpha One`，`ZWrite Off` |

加法混合的批次**不需要深度排序**（加法可交換），alpha 批次需要。0011 起 `pm_depth_order` 直接給你正交平面的 painter 置換（見 [§4.5](#45-2d-宿主投影與深度排序0011-新增)），`SpellRenderer.cs` 用的就是它；3D 透視相機的視距排序仍屬宿主（或改用加法混合的屬性）。

### 5.7 建 Mesh 的兩條路

- **簡單版**：CPU 端把每顆粒子展開成兩個三角形（4 頂點），寫進一個重複使用的 `Mesh`，`mesh.SetVertices` / `SetColors` / `SetIndices`。4096 顆＝16384 頂點，Unity 完全吃得下。
- **快版**：把六條陣列丟進 `ComputeBuffer`，用 `Graphics.DrawProcedural` 在 vertex shader 裡展開 billboard。省掉 CPU 端的展開與上傳量。這也是 demo 在 raylib 端走的路數（[ADR-0009](adr/adr-0009-dynamic-quad-mesh-rendering.md)：整批一次 draw call，draw call 數＝批次數而非粒子數）。

---

## 6. 路線 D：自製前端與其他語言

任何能載入共享庫、能宣告 C 函數的環境都接得上（Rust `extern "C"`、Python `ctypes`、Zig `@cImport`、Godot GDExtension⋯）。合約完全一樣，只有以下幾條**不分語言的規則**：

1. `pm_init()` 一次，之後不要 `pm_shutdown()`（除非你真的要結束 process）。
2. 啟動時比對 `pm_abi_version()` 與你編譯時的 `PM_ABI_VERSION`。
3. 六條陣列由**你**配置、由**你**持有，長度用 `pm_max_particles()` 查（不要用 `PM_MAX_PARTICLES` 常數，見 §2.5）；庫只往裡面寫。
4. 一個 handle 一個執行緒。
5. 固定 `dt`；一幀多步 `advance`、只 `observe` 一次。步數用 `pm_plan_steps` 規劃，**不要自己寫 `while`**——手寫的沒有單幀上限，一次卡頓就是死亡螺旋，累加器用 `float` 還會漂（見 §2.4）。
6. `pm_observe` 回負數＝什麼都沒寫；不要用上一幀的殘留資料當這一幀畫。
7. 顏色是 `0xRRGGBBAA`；位置是右手系。
8. 每個 `pm_cast` 配一個 `pm_free`。

---

## 7. 哪些事情是**你**要做的

庫刻意不做的清單。看到這裡如果覺得「怎麼這麼多」——這正是它能同時服務 Unity、Godot 和一個 raylib demo 的原因。

| 你的責任 | 為什麼不在庫裡 |
|---|---|
| 頂點緩衝、材質、shader、混合狀態 | 每個引擎都不一樣；輸出格式因此零渲染依賴（[architecture §5.2](arch/architecture.md#52-輸出格式renderbatch-串流)） |
| 相機與投影 | 3D 透視是引擎的事；2D 正交的**純數學**部分庫有提供（Haskell 宿主用 `Magic.Projection`，C 宿主用 `pm_project`／`pm_depth_order`，見 §4.5） |
| 螢幕原點、pixels-per-unit、y 軸方向 | 投影只丟軸與算深度，像素是宿主的座標系 |
| 3D 的深度排序 | 見 §5.6 |
| 多個法術同時存在時的管理與總量配額 | 宿主持有多個 handle 即可；全域配額策略屬遊戲層（[architecture §8.4](arch/architecture.md#8-未來可能遇到的問題)），[記帳在候選 spec C](roadmap.md#45-cde-的位置) |
| 魔法陣 JSON 從哪來（檔案？資料庫？玩家編輯器？） | 庫只認得字串 |
| 熱重載 | 政策是「重載＝重施法」：重新 `pm_cast` 就好，庫不提供遷移中狀態的 API（[ADR-0010 D8](adr/adr-0010-force-field-composition.md)） |
| 音效、傷害判定、命中框 | 這個庫只管粒子；魔法的**遊戲**語意是你的 |

---

## 8. 目前的限制（誠實清單）

寫在合約裡的事實，不是 bug。完整版與各自的記帳位置見 [roadmap.md](roadmap.md)。

| 限制 | 說明 |
|---|---|
| **粒子上限 16384** | **這是護欄值，不是速度上限**：func-spec 0010 已把熱路徑做到 100 000 粒 6.5 ms（60 fps 預算的 39%）；func-spec 0012 依「單幀純 CPU ≤ 2 ms」的規則把值定在 16384（實測 1.45 ms）。超過上限的魔法陣在 `pm_cast`／`castSpell` 就會被擋下（`PM_ERR_BUDGET`），不會在執行期爆掉。**請用執行期查詢，不要把數字抄進程式碼**——它已經變過一次：Haskell 宿主用 `Magic.Interface.maxSpellParticles`，C 宿主用 `pm_max_particles()`（`PM_MAX_PARTICLES` 是 ABI 第 1 代的 4096，永久凍結） |
| **不進場景的合成只在 Haskell 面** | 場景層已於 func-spec 0018 上 C ABI（§4.6，ADR-0012 D8 的延後已解除）。仍只在 Haskell 面的是 `castSpells`——把幾張陣合成一個**獨立** `ActiveSpell`。C 宿主要合成,開一個 `global_cap` 夠大的場景用 `pm_scene_cast_many` 即可,差別只在多了一個場景 handle |
| **場景不報批次歸屬** | `pm_scene_observe`（與 `observeScene`）都不告訴你某個 batch 屬於哪一張陣;要按法術分別上色／分別剔除的宿主目前得自己開多個場景。做法已知且為純加法，記在 func-spec 0018 §8-1 |
| **合成後只有一個 blend mode** | 合成法術渲染成一個 batch，混合模式取第一張陣的（ADR-0012 D5）。把火（additive）與水（alpha）疊起來，整體以第一張的模式繪製 |
| **同 handle 不保證順序** | 同一個 handle 的併發操作保證**不丟更新**（N 次併發推進恰好 N 步），但**順序**不保證；`pm_free` 與同 handle 的其他呼叫、以及推進／觀測的配對，要宿主自己序列化（§4.4.2） |
| **RTS 不可重啟** | `pm_shutdown()` 之後不能再 `pm_init()`；一個 process 一份 GHC RTS |
| **DLL 約 46 MB** | `standalone` 內嵌整個 GHC RTS 的代價；換來的是宿主端零 Haskell 依賴。（量測基準：GHC 9.14.1、Windows x86_64、`standalone` 建置的 `particle-magic-ffi.dll`，2026-08-21 實測 47,990,272 bytes ＝ 45.8 MiB） |
| **macOS 沒有任何機器驗過** | CI 矩陣是 `windows-latest` 與 `ubuntu-latest`（`.github/workflows/ci.yml`），兩個平台**每次都跑完整的 hspec 套件**，Windows 與 Linux 因此都是實測過的。macOS 的 `.dylib` 只有 cabal 的建置設定與封裝腳本（`@rpath`、`lipo`），沒有一台機器建過或跑過——`packaging/artifacts.json` 把兩個 macOS 目標記為 `verified: false`，見 §4.9 |
| **billboard 形狀是無參數列舉** | func-spec 0015 起有四種形狀碼（square／soft-dot／ring／spark），但形狀**永遠不帶參數**（拉伸、旋轉需另開查詢，ADR-0013）；怎麼畫每種形狀由宿主自行決定（demo 用 64×64 程序生成 alpha 貼圖，RGB 全白、顏色仍來自頂點色） |
| **只有 Unity 被實測過** | C# 綁定在 Unity 6000.5.7f1 batchmode 實測通過（[0011 §9.3](spec/func-0011-host-integration-surface.md)，可用 `examples/unity/PmSmoke.cs` 一鍵複驗）；Godot／Unreal／其他 .NET 宿主只有合約保證，沒有實測 |
| **空間摘要交資訊，不交判定** | func-spec 0025 給的是包絡與佔用格網（§3.1.1／§4.7），**不是**碰撞判定：「粒子撞到牆會怎樣」是遊戲層的規則。真要做碰撞回饋（粒子反彈）需要把結果送回模擬，那會是輸出第一次影響輸入，屬於另一輪。視錐剔除同理——核心沒有相機概念（ADR-0008） |
| **發動點是編譯期常數** | `"anchors"` 的位置與法線在施法時定下，**不隨時間移動**（跟隨施法者的發動點做不到）。與 0007 的時變場參數是同一筆記帳，應一起做，記在 func-spec 0025 §7-8 |
| **各發動點共用同一份符文** | N 個發動點只有位置與法線不同；「左手火、右手冰」是**兩張陣**，用 `castSpells`／`pm_scene_cast_many` 各帶自己的 `anchors`（func-spec 0025 §7-9） |
| **像素風只有食譜，沒有像素風的參考實作** | enhance-0001 補上了 §3.3 的五步與 [`examples/haskell/`](../examples/haskell/)（可跑，但不畫圖）。真正**畫出來**的 2D 參考實作只有 demo 的 flat view（`App.Render.Flat`），而它是連續色彩＋64×64 程序貼圖——§3.3 第 3、4 條（低解析 render target 整數倍放大、調色盤量化）**沒有任何範例走過**，只有做法 | 

---

## 9. 版本與相容性承諾

| 合約 | 承諾 |
|---|---|
| `include/particle_magic.h` | **只加不改**。既有的每個函數簽名、常數值、`batch_info` 佈局都不會變。新增功能＝新增宣告 |
| `pm_abi_version()` | 上述承諾破裂時（如果真有那一天）才會遞增。啟動時比對它 |
| 魔法陣 JSON `"version"` 欄位 | schema v1。未來遞增時，`Magic.Codec` 保留舊版解碼器並提供 migrate，舊魔法檔不會失效 |
| `PM_MAX_PARTICLES` vs `pm_max_particles()` | 常數**永遠**是第 1 代的 4096（header 凍結）；查詢跟著核心走。核心提升上限時 header 一字不動，用查詢配置的宿主不必重編。**已驗證**：func-spec 0012 把核心上限提到 16384，header 零字元變更、既有宿主零重編譯 |
| Haskell 側 `Magic.Interface` / `Magic.Codec` / `Magic.Projection` / `Magic.Columns` | 各自的 func-spec 驗收紀錄明列「凍結介面清單」；凍結後的變更視同架構變更，要先改 ADR |
| `bindings/csharp/ParticleMagic.cs` | 不是凍結合約，是**參考實作**；但它與 header 的一致性由 `test/BindingContractSpec.hs` 守護，不會偷偷落後 |
| 決定論 | 同一組輸入永遠產生逐位元相同的輸出，且**兩條路徑（Haskell／C ABI）的結果相同**——這不是文件承諾，是 `test/Acceptance9Spec.hs`（取樣）與 `test/Acceptance11Spec.hs`（投影）的斷言 |
