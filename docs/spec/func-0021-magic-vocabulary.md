---
id: func-0021
type: spec
title: magic-vocabulary
description: 魔法語彙擴張 —— 五行陰陽等四個 sum type 由 POC 值域擴到遊戲級,全部是加法。
status: open
created: 2026-08-15
updated: 2026-08-16
depends-on: [func-0020]
related-adr: [adr-0003, adr-0005, adr-0010]
---

# Func-Spec 0021：魔法語彙擴張（五行陰陽、形狀、軌跡、力場、輻射）

> 狀態：**設計定案，待實作**
> 性質：一般 —— 新增的建構子與其 JSON tag 依 0002 §2 的可擴充 sum 合約，交付後凍結（只加不改）。**`Element` 的宣告序自本輪起視同 wire code**（§2.4）。
> 前置依賴：**spec 0020（需已完成）**——本 spec 修改 `src/core/Magic/Particle/Analytic.hs`（`sampleShape`／軌跡取樣），與 0020 的 `positionIn` 改動同檔，依 SKILL.md 規則 4 **動工門檻＝0020 驗收**。**與 spec 0018／0019 平行**（0018 觸 `src/ffi`＋`include`＋`bindings`，0019 觸 `.github`＋cabal metadata；本 spec **不觸碰 `include/particle_magic.h`**——見 §2.3 的 blend 裁決——故交集 = ∅，§0.2）。
> 依據：architecture **§10**（七個擴充點的機制保證：「新符文／新初始面形狀／新屬性元素」三列各自宣稱「便宜」——**本輪是這三句話的第一次大規模兌現**）、§11（不容易擴充的硬點表，本輪逐條避開）；[roadmap.md](../roadmap.md) §2.1（「機制 100%／實例 POC 級——值域很小」）、§3.4（俯視進階可讀性）、§4.7 候選 G；ADR-0003（槽位固定職責）、ADR-0005（JSON schema 的加法演進）、ADR-0010（力場僅場對粒子）；spec 0015 §8-5（**「複數 blend 的批次要等多元素魔法陣」——本輪結清**）、0013 §8-4／0008 §9-8（俯視可讀性只解到第一階）。
> 範圍：把四個 sum type 從 POC 級值域擴到遊戲級——`Element` 4→9（**五行＋陰陽**）、`FaceShape` 4→8、`Trajectory` 4→8、`ForceField` 3→6、`RadiationMode` 2→4——並順帶收掉俯視進階可讀性。**全部是加法**：既有建構子、既有語意、既有 JSON tag 一個字都不動，因此既有範例陣的輸出**逐位元不變**（§1-1，本輪最強的一條律）。

---

## 0. 起點：引用的凍結介面、檔案盤點

### 0.1 引用的凍結介面

| 凍結物 | 本 spec 的用法 |
|---|---|
| `Element`／`FaceShape`／`Trajectory`／`ForceField`／`RadiationMode`（0002／0007 凍結，可擴充 sum） | **只加建構子，既有的一律附加在後**（§2.4 的 append-only 律） |
| `elementAppearance :: Element -> Appearance`（0002；註解明文「唯一讓本質影響外觀的地方，封閉影響面」） | 加 5 列。**這句註解就是本輪便宜的原因**——新元素的影響面被關在一張表裡 |
| `sampleShape`（`Analytic.hs`）、`shapeRadius`（`Compile.hs`，0010 S7 的保守 AABB） | 各加 4 個 case。新形狀**必須**同時給出保守上界，否則 0010 的剔除會漏粒子（§2.2） |
| `fieldAccel :: [ForceField] -> V3 -> V3`（0007／0010 凍結簽名） | **簽名零變更**——這是本輪選擇哪三種新場的**硬性篩選條件**（§2.5） |
| `Field.step` 的半隱式尤拉、穩定槽位身分（ADR-0010 D1／D2） | 零變更 |
| `BlendMode`＝`{BlendAlpha, BlendAdditive}`＋`PM_BLEND_*` wire code（0005／0009 凍結） | **零變更**（§2.3 的裁決）——這是本 spec 能與 0018 平行的關鍵 |
| `observeSpell` 依 `(blend, shape)` 相鄰 run-length 分批（0015 S1 凍結分割律） | **零變更**；本輪只是第一次讓「同一個 `FrameOutput` 內出現複數 blend」真的發生 |
| `docs/spell-schema.md` 的鍵名機械守護（0014 `SchemaDocSpec`） | 新 tag **強制**同步文件，否則測試紅 |
| `Magic.Sigil`／`SigilSpin`（0016／0020 凍結） | **唯讀**：新 `FaceShape` 經 0016 §3 的 `ShapeRune` 例外參與陣形；本 spec 不碰 `Sigil.hs` |
| 核心依賴白名單 `{base, vector, deepseq}` | 不新增依賴 |

### 0.2 檔案盤點（與 0018／0019 的三方零交集證明）

**修改（7）**：

| 檔案 | 變更 |
|---|---|
| `src/core/Magic/Rune.hs` | 五個 sum type 各加建構子（+5／+4／+4／+3／+2） |
| `src/core/Magic/Compile.hs` | `elementAppearance` +5 列、`shapeRadius` +4 case、軌跡→`Motion` +4 case、輻射軸 +2 case |
| `src/core/Magic/Particle/Analytic.hs` | `sampleShape` +4、軌跡位置 +4、輻射軸 +2 |
| `src/core/Magic/Particle/Field.hs` | `fieldAccel` +3 case（簽名不變） |
| `src/boundary/Magic/Codec.hs` | 新 tag 的編解碼（18 個建構子）＋參數驗證 |
| `docs/spell-schema.md` | 新鍵名段落（`SchemaDocSpec` 強制） |
| `app/App/Render/Flat.hs`＋`app/App/Camera.hs` | 俯視進階可讀性：深度壓平比例、輪廓強調（S6） |

**新增（8）**：`test/ElementVocabSpec.hs`、`test/FaceShapeVocabSpec.hs`、`test/TrajectoryVocabSpec.hs`、`test/FieldVocabSpec.hs`、`test/VocabCodecSpec.hs`、`test/FlatReadabilitySpec.hs`、`test/Acceptance21Spec.hs`、`assets/spells/wuxing-seal.json`＋`assets/spells/yin-yang.json`。

**共用（行級聯集合併）**：`particle-magic.cabal`（test other-modules +7）、`SKILL.md`、`docs/roadmap.md`、`CHANGELOG.md`。

**明文不碰**：`include/particle_magic.h`（**§2.3**）、`src/ffi/*`、`particle-magic-ffi.def`、`bindings/*`、`examples/*`、`src/core/Magic/{Circle,Expr,Project,Types,Sigil}.hs`、`src/core/Magic/Particle/Buffer.hs`、`src/boundary/{Interface,Projection,Scene,Columns,Step}.hs`、`tools/*`、`bench/*`。

**三方交集**：0018 觸 `src/ffi`＋`include`＋`.def`＋`bindings`＋`examples`＋三個 FFI 測試模組；0019 觸 `.github/`＋README＋`docs/release.md`＋cabal metadata。與本清單逐檔比對：**交集 = ∅**。

> **與 0024 的關係**：0024（作者工具第二輪）分兩半——`tools/` 半場與本 spec **零交集、可平行**；`app/` 半場（demo 內的參數面板）確實碰 `app/*`，但其動工門檻為 **0023 驗收**，而 0023 排在本 spec 之後（0021 → 0022 → 0023 → 0024 的鏈序），故**依鏈序自然序列化，不需額外約定**。詳見 0024 §0.3。

---

## 1. 目標與完成定義

**目標**：architecture §10 說七個擴充點「便宜」，roadmap §2.1 說「機制 100%／實例 POC 級」。本輪把宣稱換成數字。

同時解掉一個具體的表達力缺口：目前**任何**魔法都只有一個 blend mode，因為 blend 只由 `Element` 決定而元素只有四種、實際只分成兩群。0015 交付了依 `(blend, shape)` 分批的機制，卻沒有素材讓它發揮——這是機制與值域脫節最明顯的一處。

**完成定義**：

1. **逐位元相容律（本輪最強的一條）**：既有 11 個範例陣的 `FrameOutput`、240 幀、逐位元不變。本輪全部是加法，既有 case 一個字不動——這條律若紅，代表有人動了不該動的東西（S7）。
2. `Element` 9 種：`Neutral`／`Fire`／`Water`／`Lightning`（既有，位置不動）＋`Metal`／`Wood`／`Earth`／`Yin`／`Yang`（新）。每種有顏色曲線與 blend，且**至少一種新元素走 `BlendAlpha`、至少一種走 `BlendAdditive`**（S1）。
3. `FaceShape` 8 種：＋`Polygon`／`Star`／`Cross`／`Sector`。每種有 `sampleShape` 與**保守上界** `shapeRadius`，且 `|p| ≤ shapeRadius` 為 property（S2）。
4. `Trajectory` 8 種：＋`Wave`／`Ballistic`／`Pulse`／`Zigzag`。全部是粒子年齡的閉式函數，必有限（S3）。
5. `ForceField` 6 種：＋`Wind`／`Turbulence`／`Spring`。**`fieldAccel` 簽名零變更**，`Field.step` 零變更（S4）。
6. `RadiationMode` 4 種：＋`RadialInward`／`TangentialSwirl`（S5）。
7. 18 個新建構子全部有 JSON tag、round-trip 成立、參數驗證有錯誤訊息、`docs/spell-schema.md` 同步（S5）。
8. **複數 blend 批次律**：新範例陣 `wuxing-seal.json` 產生的 `FrameOutput` 含**至少兩個不同 `rbBlend` 的 batch**——0015 §8-5 的記帳在此結清（S7）。
9. 俯視進階可讀性：深度壓平比例與輪廓強調可切換，headless 可測（S6）。

## 2. 使用到的架構與技巧

- **加法即全部**：18 個新建構子，零個既有 case 被修改。GHC 的 exhaustiveness check 會逐一指出所有必須補 case 的地方——architecture §10 說的「不動介面」在本輪的具體意義是：`Magic.Interface`、`include/particle_magic.h`、`ParticleBuffer` 的六欄、`CompiledSpell` 的結構，全部一個字不動。
- **本輪是擴充成本的實測**：每份 spec 的 §9 都回填數字；本輪要回填的是「一個新建構子平均要改幾個檔案、寫幾條測試」。若這個數字很大，architecture §10 那張表就需要修訂——那是比新增五種元素更有價值的產出。

### 2.1 五行＋陰陽的映射（`elementAppearance` 的 5 個新列）

| 元素 | 顏色曲線（0xRRGGBBAA 起→迄） | blend | 理由 |
|---|---|---|---|
| 金 `Metal` | `0xFFF2CCFF` → `0xB38F1A66` | **Additive** | 銳利反光；additive 讓交疊處爆白 |
| 木 `Wood` | `0x99E680FF` → `0x2E661A33` | Alpha | 生長、遮蔽感；additive 會讓綠色發光不像木 |
| 土 `Earth` | `0xD9B380FF` → `0x59401A00` | Alpha | 厚重不透光——alpha 是它的語意而非退讓 |
| 陰 `Yin` | `0x6633AAFF` → `0x0D0A1A00` | Alpha | **暗色低 alpha**：陰的「吸光」用暗色 alpha 表達（不加新 blend，見 §2.3） |
| 陽 `Yang` | `0xFFFFE0FF` → `0xFFCC4D00` | **Additive** | 放光，與陰成對 |

既有四種（Neutral Alpha／Fire Additive／Water Alpha／Lightning Additive）不動。九種的 blend 分佈是 **5 Alpha／4 Additive**——這保證任何混用兩群元素的合成陣都會產生複數 blend 的批次（§1-8）。

### 2.2 新形狀必須自帶保守上界（否則 0010 的剔除會漏）

0010 S7 的 `emitterBounds` 用區間算術得到保守 AABB，其中形狀那一項來自 `shapeRadius`。新增 `FaceShape` 建構子若忘了補 `shapeRadius` 的 case，GHC 會擋（exhaustiveness），但**給錯一個太小的界不會被編譯器擋** —— 那會讓視錐剔除把還在畫面內的發射器丟掉，症狀是「某個角度看粒子會整批消失」，而且只在宿主真的做視錐剔除時才發作。

因此 S2 的測試把它寫成 property：對每個新形狀、每個索引，`|sampleShape shape i| ≤ shapeRadius shape`。這條 property 對既有四種形狀也套用（免費的回歸網）。

四個新形狀的界：`Polygon n r → r`、`Star n ro ri → ro`、`Cross len w → sqrt(len² + (w/2)²)`、`Sector r0 r1 θ → r1`。

### 2.3 為什麼不加第三種 blend（本輪與 0018 能平行的關鍵）

陰屬性直觀上想要**減色／相乘**混合。但 `BlendMode` 的建構子宣告序就是 `PM_BLEND_*` 的 wire code——加一個建構子等於改 `include/particle_magic.h`、`.def`、C# 綁定與 `FFIContractSpec`，而那**恰好是 spec 0018 鎖住的檔案集合**。兩份 spec 就得排序，而它們本來完全無關。

裁決：**陰用暗色低 alpha 表達，不加 blend**。這不只是為了平行——`BlendMode` 是跨越 C ABI 的詞彙，它的擴充應該由一份**知道自己在動 C 合約**的 spec 負責（形狀是 0015 的先例：它加 `PM_SHAPE_*` 時是全程知情的）。混在語彙擴張輪裡順手加，是把 ABI 變更藏在不相干的 commit 裡。

記帳（§8-1）：第三種 blend 的形狀已知——`BlendMode` 加建構子 ⇒ `PM_BLEND_*` +1 ⇒ header／`.def`／C# 綁定／`FFIContractSpec` 同步（純加法，wire code 由 `fromEnum` 自動導出，0015 已鋪好這條路）。

### 2.4 `Element` 的宣告序自本輪起視同 wire code

`Element` 目前不上 C ABI（wire 上跑的是 blend 與 shape，不是元素）。但它 `deriving (Enum, Bounded)`，而 0015 已經立下「宣告索引即 wire code」的先例；更重要的是 **0016 的 `hashCircle` 對 `Circle` 全結構做摘要，元素的序數是摘要的輸入之一**——在既有元素之間插入新建構子會改變所有既存法術的 `hashCircle`，也就**靜默改變它們的陣長什麼樣**（ADR-0014 的「摘要即合約」）。

所以規則寫死：**新元素一律附加在 sum 的尾端**，既有四種的位置永不移動。這條規則對本輪的其他四個 sum type 同樣適用，理由相同。S1 的測試以 `[minBound .. maxBound]` 的前四項見證。

### 2.5 三種新場的篩選條件：不能看速度

`fieldAccel :: [ForceField] -> V3 -> V3` 只吃位置。這是 0007／0010 的熱路徑核心，`Field.step` 的半隱式尤拉與 `FieldState` 的攤平 unboxed 佈局都建立在它之上。

因此本輪的三種新場**必須是純位置函數**：

| 新場 | 加速度 | 為何純位置 |
|---|---|---|
| `Wind !V3 !Float !Float` | `dir · strength + 位置雜湊導出的擾動 · turbulence` | 擾動由位置雜湊（沿用 `hashChan` 的算術）導出，零狀態 |
| `Turbulence !Float !Float` | 位置雜湊導出的三分量無散度場 × `strength`，尺度由 `scale` | 同上 |
| `Spring !V3 !Float` | `−k · (pos − center)` | 線性回復力。與 `PointAttractor` 的差別：不隨距離衰減、無奇異點、**會產生穩定的簡諧振盪**而非墜落 |

**速度相依的場（阻尼 `Drag`、磁力 `Magnetic`）明確不做**（§8-2）：它們要求 `fieldAccel` 看得到速度，那是簽名變更＋熱路徑改寫，應該由一份專門處理它的 spec 負責，而不是夾帶。這也是一個誠實的發現——architecture §10 說擴充便宜，但**只有在擴充落在既有簽名之內時才便宜**；`Drag` 是「不便宜的擴充」的第一個實例，值得寫進 §9 回填。

### 2.6 俯視進階可讀性（S6）

0013 交付了第一解（深度色調）。0008 §9-8 暴露的問題是：俯視（丟 Y）把沿法線擠出的立體結構壓成一團。第二解兩件事，都住在 `app/*`：

1. **深度壓平比例**：投影後對深度做非線性壓縮（可調係數），讓遠近的尺寸差被放大——近的更大、遠的更小，恢復被正交投影抹掉的深度線索。
2. **輪廓強調**：對 alpha batch，依深度調整 billboard 尺寸的下界，讓最近的一層有可辨識的邊緣。

兩者都是 staging 層的純變換，**核心零觸碰**，headless 可測（比照 0013 的 `DepthTintSpec`）。

## 3. ADT

```haskell
-- src/core/Magic/Rune.hs（全部加法，一律附加在尾端——§2.4）

data Element
  = Neutral | Fire | Water | Lightning        -- 既有，位置永不移動
  | Metal | Wood | Earth | Yin | Yang         -- 新（五行的金木土＋陰陽）
  deriving (Eq, Show, Enum, Bounded)

data FaceShape
  = HollowSquare !Double | Rect !V2 | Ring !Double !Double | Diamond !Double
  | Polygon !Int !Double            -- 正 n 邊形：頂點數、外接半徑
  | Star    !Int !Double !Double    -- 星形：尖角數、外半徑、內半徑
  | Cross   !Double !Double         -- 十字：臂長、臂寬
  | Sector  !Double !Double !Double -- 扇形：內半徑、外半徑、張角（rad）
  deriving (Eq, Show)

data Trajectory
  = Forward !Double | Spiral !Double !Double !Double | Orbit !Double !Double | {- 既有的公式軌跡 -} ...
  | Wave      !Double !Double !Double  -- 前進速度、橫向振幅、頻率（Hz）
  | Ballistic !Double !Double          -- 初速、重力加速度（解析拋物，不需力場）
  | Pulse     !Double !Double          -- 平均速度、脈動頻率（衝—緩—衝）
  | Zigzag    !Double !Double !Double  -- 前進速度、橫向幅度、轉折頻率（硬轉折）
  deriving (Eq, Show)

data ForceField
  = Gravity !V3 | PointAttractor !V3 !Float !Float | Vortex !V3 !V3 !Float !Float
  | Wind       !V3 !Float !Float   -- 方向、強度、擾動量
  | Turbulence !Float !Float       -- 強度、空間尺度
  | Spring     !V3 !Float          -- 中心、勁度 k
  deriving (Eq, Show)

data RadiationMode
  = AlongNormal | RadialOutward
  | RadialInward      -- 向面心收束
  | TangentialSwirl   -- 沿面切線（繞面心）
  deriving (Eq, Show)
```

### 3.1 JSON tag（`Magic.Codec` 加法；`docs/spell-schema.md` 同步）

元素：`"metal"`／`"wood"`／`"earth"`／`"yin"`／`"yang"`。
形狀：`{"kind":"polygon","sides":6,"radius":1.5}`／`"star"`（`points`／`outer`／`inner`）／`"cross"`（`length`／`width`）／`"sector"`（`inner`／`outer`／`sweep`）。
軌跡：`"wave"`／`"ballistic"`／`"pulse"`／`"zigzag"`。
力場：`{"kind":"wind","dir":[…],"strength":…,"turbulence":…}`／`"turbulence"`／`"spring"`。
輻射：`"radial-inward"`／`"tangential-swirl"`。

參數驗證（比照 0007 的 `softening > 0`）：`sides ≥ 3`、`points ≥ 2`、`outer > inner ≥ 0`、`width > 0`、`0 < sweep ≤ 2π`、`scale > 0`、`k > 0`、`turbulence ≥ 0`、頻率 ≥ 0。失敗回既有的載入錯誤型別，附鍵路徑。

## 4. 資料流

本輪**不改變任何資料流**——五個 sum type 的新建構子流過的是與既有建構子完全相同的管線（compile fold 步驟 1／2／4、`sampleShape`、`fieldAccel`）。這件事本身就是 architecture §10 的論點：擴充點之所以便宜，正是因為它們不引入新的流。

唯一的新流是 S6 的俯視可讀性，且它完全在 `app/*` 的 staging 層（0013 已建立的位置）。

## 5. 搭建方式（風險優先）

1. **S1 `Element`**——最先，因為 §2.4 的 append-only 律與 `hashCircle` 的耦合是本輪唯一「做錯就靜默破壞既有法術」的地方。
2. **S2 `FaceShape`**——`shapeRadius` 的保守界是第二個「做錯不會被編譯器擋」的地方（§2.2）。
3. **S3 `Trajectory`**、**S4 `ForceField`**——各自獨立，可同時進行。
4. **S5 `RadiationMode`＋全部 Codec tag＋schema 文件**——一次收齊 18 個 tag，避免分批漏掉。
5. **S6 俯視可讀性**——`app/*`，與 S1–S5 無依賴。
6. **S7 端到端＋兩個新範例陣**。

## 6. Todo List 與 1-to-1 測試對應

| # | Todo | 測試 |
|---|---|---|
| S1 | `Element` +5（`Metal`／`Wood`／`Earth`／`Yin`／`Yang`）＋`elementAppearance` 5 列 | `test/ElementVocabSpec.hs`（**append-only 律**：`[minBound..maxBound]` 前四項 ≡ `[Neutral,Fire,Water,Lightning]`；九種各有相異的 `ColorRamp`；blend 分佈含至少一種新 Alpha 與一種新 Additive；`Neutral` 仍逐位元 ≡ 0001 的素放外觀；每種的 `rampStart`／`rampEnd` alpha 於生命末端趨零） |
| S2 | `FaceShape` +4＋`sampleShape` 4 case＋`shapeRadius` 4 case | `test/FaceShapeVocabSpec.hs`（**保守界 property**：`\|sampleShape s i\| ≤ shapeRadius s`，全 8 種 × 隨機索引；`Polygon n r` 的取樣落在 n 邊形內；`Star` 的外/內半徑分佈；`Cross` 的臂寬界；`Sector` 的張角界；全分量有限；既有四種的取樣**逐位元不變**） |
| S3 | `Trajectory` +4＋位置取樣 4 case | `test/TrajectoryVocabSpec.hs`（全部為粒子年齡的閉式函數：同齡同輸出（決定論）、有限值（property，含極端年齡）；`Wave` 橫向分量的週期性；`Ballistic` 的頂點時刻 ≡ 解析解；`Pulse` 的位移單調不減；`Zigzag` 的轉折次數 ≡ 頻率×時間；既有四種逐位元不變） |
| S4 | `ForceField` +3＋`fieldAccel` 3 case（**簽名不變**） | `test/FieldVocabSpec.hs`（`fieldAccel` 對三種新場為純位置函數：同位置同加速度、有限值（property）；`Spring` 的線性律 `a(2p) = 2a(p)` 對中心平移後成立；`Turbulence`／`Wind` 的擾動決定論且有界；**零場快路徑不受影響**（空場清單仍結構性跳過，ADR-0010 D9）；既有三種逐位元不變） |
| S5 | `RadiationMode` +2＋18 個 JSON tag 的 Codec 編解碼與參數驗證＋`docs/spell-schema.md` | `test/VocabCodecSpec.hs`（18 個新建構子的 round-trip `saveCircle`→`loadCircle` 恆等（property）；每條參數驗證各一個失敗見證＋錯誤訊息含鍵路徑；未知 tag 仍回既有錯誤型別；**`SchemaDocSpec` 的鍵名守護連帶全綠**——新鍵未寫進文件即紅） |
| S6 | 俯視深度壓平比例＋輪廓強調（`app/App/Render/Flat.hs`／`Camera.hs`） | `test/FlatReadabilitySpec.hs`（壓平係數為 1 時 ≡ 0013 的既有投影逐位元（零輸入零漣漪律，0013 的慣例）；係數 > 1 時深度差被放大且保序；輪廓強調的尺寸下界恆 > 0 且不改變粒子位置；headless 解譯器可觀測） |
| S7 | 端到端＋`assets/spells/wuxing-seal.json`（混用五行、產生複數 blend）＋`assets/spells/yin-yang.json`（陰陽對置、驗證新形狀與新軌跡） | `test/Acceptance21Spec.hs`（**逐位元相容律**：既有 11 個範例陣 240 幀 `FrameOutput` 逐位元不變；**複數 blend 批次律**：`wuxing-seal` 的 `FrameOutput` 含至少兩個相異 `rbBlend`（0015 §8-5 結清）；兩個新陣 240 幀決定論；`spellBudget = Σ emCount`；`magic-validate` 對兩個新陣 exit 0） |

## 7. 非目標

1. **第三種 `BlendMode`**（減色／相乘）——§2.3 的裁決。形狀已知（`PM_BLEND_*` +1，純加法），但它動 C 合約，應由知情的 spec 負責。
2. **速度相依的力場**（`Drag` 阻尼、`Magnetic`）——§2.5。需要 `fieldAccel` 看得到速度＝簽名變更＋熱路徑改寫。**這是本輪發現的第一個「不便宜的擴充點」**，值得單獨一輪並回頭修訂 architecture §10 的措辭。
3. **粒子對粒子互動**——architecture §7 的永久非目標，不因場的種類變多而鬆動。
4. **屬性相剋／相生的遊戲語意**（五行的生剋關係影響傷害或粒子行為）——本輪只給**外觀與行為的詞彙**，不給規則。相生相剋是遊戲層的設計（architecture §8.1 的立場：組合平衡交遊戲層）；五行體系被選中的理由之一正是它日後**有現成的語意結構**可接。
5. **新的 `BillboardShape`**——0015 §8-1 的 `PM_BATCH_INFO_STRIDE` 凍結論證不變；本輪不碰形態詞彙。
6. **新 `StrokeKind`（第七種筆畫）**——`Magic.Sigil` 是 0016／0020 的地盤，本輪零觸碰。新 `FaceShape` 會經 0016 §3 的 `ShapeRune` 例外自動參與陣形，那是免費的紅利，不是本輪的工作。
7. **`Expr` 的新運算子**——architecture §10 的另一個擴充點，與本輪無關；`Expr` 語言合約由 0003 凍結。
8. **屬性數量對 `hashCircle` 的重新平衡**——元素從 4 變 9 讓摘要的元素位段值域變大，但摘要函數本身不變（§2.4 只要求 append-only）。若日後發現陣的分佈變差，那是 `Magic.Sigil` 的問題。

## 8. 驗收紀錄

（實作時回填：日期、`cabal test` 結果、**擴充成本實測**——每個新建構子平均觸及檔案數與測試條數，以及它與 architecture §10「便宜」宣稱的對照；`Drag` 被排除的理由是否需要回頭修訂 §10 的措辭；與計畫的差異。）
