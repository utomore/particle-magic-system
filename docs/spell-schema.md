---
id: spell-schema
type: reference
title: spell-file-schema
description: 寫魔法陣 JSON 的作者手冊，只講鍵名與值域
status: done
created: 2026-08-15
updated: 2026-08-16
related-adr: [adr-0005]
related-spec: [func-0014]
---

# 法術檔案格式（schema v1）—— 作者手冊

本文是**寫魔法陣 JSON 的人**的參考，不是程式碼說明。全文只講 JSON 鍵名與值域；型別名、模組名一律不出現。

- 檔案放在 `assets/spells/`，副檔名 `.json`，demo 會掃描整個目錄並以方向鍵切換。
- 改檔存檔後 demo 會**熱重載**；新增或刪除檔案也不必重啟（清單每 2 秒重掃一次）。
- 想在不開視窗的情況下確認一個檔案是否正確：`cabal run magic-validate -- --stats assets/spells`（見 §8）。

> 機械守護：`test/SchemaDocSpec.hs` 斷言「範例檔中出現的每一個物件鍵名都出現在本文」。所以本文寫漏欄位，`cabal test` 會紅。

---

## 1. 心智模型：魔法陣 = 由內而外的四層

一張魔法陣（circle）有四個**角色固定**的區域，每個槽位都可留空、可自由組合。解釋器由內而外讀它，每一層負責一件事：

| 區域 | JSON 鍵 | 角色 | 一句話 |
|---|---|---|---|
| 核心 | `core` | **本質** | 這是什麼法術：元素、威力、方向偏壓 |
| 內圈（2 層） | `inner` | **行為** | 粒子怎麼動、活多久 |
| 夾層（1 層） | `bridge` | **調變** | 把內圈的行為再折彎一次 |
| 外圈（2 層） | `outer` | **呈現** | 粒子從哪裡生出來、往哪個方向散 |

再加上三個**選配**的陣級設定：`phases`（生命週期分段：先畫陣、再收束、才施放）、`fields`（力場：重力／吸引子／渦流）與 `anchors`（發動點：法術從哪幾個位置射出來）。

順序不是慣例而是語意：內圈先決定行為 → 夾層調變它 → 外圈決定它從哪裡發散。同一圈的兩層若放了**同類**符文，索引 1（外層）覆蓋索引 0（內層）。

---

## 2. 檔案骨架

```json
{
  "version": 1,
  "name": "my-spell",
  "circle": {
    "phases": null,
    "outer":  [ /* 0~2 個符文，或 null */ ],
    "bridge": null,
    "inner":  [ /* 0~2 個符文，或 null */ ],
    "core":   { "center": null, "nodes": {} },
    "fields": [],
    "anchors": null
  }
}
```

| 鍵 | 必填 | 值 | 說明 |
|---|---|---|---|
| `version` | ✅ | 整數 | 目前只接受 `1`。其他值會回報「不支援的版本」。 |
| `name` | ○ | 字串 | 給人看的名字；系統不使用它。 |
| `circle` | ✅ | 物件 | 陣本身。`"circle": {}` 是合法的最小法術（見 `empty.json`）。 |

**空槽位的三種寫法完全等價**：鍵不存在、鍵的值是 `null`、陣列中該位置是 `null`。所以任何一段都可以整段刪掉。

`outer` 與 `inner` 是**長度 0～2 的陣列**：索引 0 = 內側層，索引 1 = 外側層。放第 3 個元素是錯誤。

---

## 3. `core`：本質層

```json
"core": {
  "center": { "element": "fire", "power": 1.5 },
  "nodes": {
    "north": { "rune": "dir-bias", "strength": 0.4 },
    "south": null,
    "east":  null,
    "west":  null
  }
}
```

### 3.1 `center`：中心節點（元素與威力）

| 鍵 | 值 | 說明 |
|---|---|---|
| `element` | 九種之一，見下表 | 決定顏色漸層與混色模式。 |
| `power` | 數字，**必須 > 0** | 粒子數 = `round(256 × power)`，下限 1。`power` 太大會編譯失敗（見 §9）。 |

九種元素——四種基本加上五行的金木土與陰陽：

| `element` | 感覺 | 混色 |
|---|---|---|
| `"neutral"` | 素白，不上色（不寫 `center` 就是它） | alpha |
| `"fire"` | 橘紅、燒盡 | 加色 |
| `"water"` | 水藍、透 | alpha |
| `"lightning"` | 慘白、刺眼 | 加色 |
| `"metal"` | 金 —— 銳利反光，交疊處爆白 | 加色 |
| `"wood"` | 木 —— 生長的綠，會遮蔽 | alpha |
| `"earth"` | 土 —— 厚重不透光 | alpha |
| `"yin"` | 陰 —— 暗紫，像把光吸掉 | alpha |
| `"yang"` | 陽 —— 暖白放光，與陰成對 | 加色 |

**一張陣只有一種混色模式**，因為混色由元素決定而一張陣只有一個元素。想在同一畫面同時看到兩種混色，要把兩張陣**疊起來施放**（宿主端一次送多張陣；`wuxing-seal` 與 `yin-yang` 就是為此準備的一組）。

`center` 留空 = `neutral`、`power` 1（即 256 顆）。

### 3.2 `nodes`：上下左右四個節點

四個鍵 `north` / `south` / `east` / `west`，各自可放一個符文或 `null`。目前只有一種：

| `rune` | 鍵 | 值 | 效果 |
|---|---|---|---|
| `"dir-bias"` | `strength` | 數字（可負） | 給粒子一個等速漂移。`north` = 陣面上方，`east` = 陣面右方，`south`／`west` 為其反向。四個節點的貢獻相加。 |

節點同時也是「畫陣」階段的裝飾點——有放符文的節點，在 `phases` 開啟時會多畫一小簇粒子。

---

## 4. `inner`：行為層（最多 2 層）

每個元素是一個物件，用 `rune` 標明種類。合法的 `rune` 值：`"trajectory"`、`"timing"`、`"formula"`。

### 4.1 `"trajectory"`：軌跡

用 `kind` 分七種。全部都是**粒子年齡的閉式函數**——同一顆粒子在同一個年齡永遠算出同一個位置，所以法術可重播。

| `kind` | 額外的鍵 | 說明 |
|---|---|---|
| `"forward"` | `speed`（數字） | 沿法線直線前進。 |
| `"spiral"` | `speed`、`radius`（**> 0**）、`freq` | 邊前進邊繞圈。`freq` 是每秒圈數。 |
| `"orbit"` | `radius`（**> 0**）、`freq` | 只繞圈不前進。 |
| `"wave"` | `speed`、`amplitude`、`freq`（**≥ 0**） | 邊前進邊左右擺（正弦）。`amplitude` 是擺幅，`freq` 是每秒幾個週期。 |
| `"ballistic"` | `speed`、`gravity` | 拋物線：以 `speed` 射出，被 `gravity` 拉回。最高點在 `speed / gravity` 秒。**不需要力場**，這是解析算出來的。 |
| `"pulse"` | `speed`、`freq`（**≥ 0**） | 一衝一緩地前進。`speed` 是平均速度，`freq` 是每秒脈動幾次。**永遠不會倒退**。 |
| `"zigzag"` | `speed`、`amplitude`、`freq`（**≥ 0**） | 和 `wave` 一樣但轉折是硬的（三角波）。`freq` 是**每秒轉幾次向**。 |

不放 `trajectory` 時的預設：`forward`，`speed` 4。

```json
{ "rune": "trajectory", "kind": "zigzag", "speed": 4.0, "amplitude": 0.6, "freq": 6.0 }
```

```json
{ "rune": "trajectory", "kind": "spiral", "speed": 6.0, "radius": 0.4, "freq": 2.0 }
```

### 4.2 `"timing"`：時間包絡（三個都必填）

| 鍵 | 限制 | 說明 |
|---|---|---|
| `delay` | ≥ 0 | 施放後隔多久開始生粒子。 |
| `duration` | ≥ 0 | 生粒子的時間窗有多長（所有粒子在此窗內錯開誕生）。 |
| `lifetime` | **> 0** | 每顆粒子活多久。 |

法術總長 = `delay + duration + lifetime`（若有 `phases`，`delay` 會再加上前奏長度）。不放 `timing` 時的預設是 `delay` 0、`duration` 8、`lifetime` 2。

### 4.3 `"formula"`：自訂軌跡公式

三個鍵 `x`、`y`、`z`，各是一段**公式字串**（語法見 §7）。它取代 `trajectory`——兩者放在同一圈時，索引大的那個勝出。

```json
{ "rune": "formula", "x": "sin(t*3)*0.6", "y": "sin(t*2)*0.6", "z": "t*2" }
```

---

## 5. `bridge`：調變層（單一槽位）

一個物件或 `null`。合法的 `rune` 值：`"phase"`、`"converge"`、`"amplify"`。

| `rune` | 鍵 | 限制 | 效果 |
|---|---|---|---|
| `"phase"` | `shift` | ≥ 0 | 整段包絡往後延 `shift` 秒。 |
| `"converge"` | `expr` | 公式字串 | 橫向收束係數：1 = 原樣，0 = 完全收到軸線上。 |
| `"amplify"` | `expr` | 公式字串 | 粒子尺寸的倍率曲線。 |

```json
"bridge": { "rune": "converge", "expr": "1 - life" }
```

---

## 6. `outer`：呈現層（最多 2 層）

合法的 `rune` 值：`"shape"`、`"radiate"`、`"range"`、`"style"`。

### 6.1 `"shape"`：粒子從哪個圖形上生出來

`shape` 鍵下是一個物件，用 `kind` 分八種：

| `kind` | 額外的鍵 | 限制 | 樣子 |
|---|---|---|---|
| `"ring"` | `rInner`、`rOuter` | 兩者 **> 0** 且 **`rInner` < `rOuter`** | 圓環帶 |
| `"hollow-square"` | `size` | **> 0**（正方形邊長） | 方框（中心空） |
| `"rect"` | `w`、`h` | 兩者 **> 0** | 實心矩形 |
| `"diamond"` | `size` | **> 0** | 實心菱形 |
| `"polygon"` | `sides`、`radius` | `sides` **≥ 3**、`radius` **> 0** | 正 n 邊形（實心）。`radius` 是外接圓半徑。 |
| `"star"` | `points`、`outer`、`inner` | `points` **≥ 2**、`outer` **> 0**、`inner` **≥ 0** 且 **`inner` < `outer`** | 星形（實心）。`points` 是尖角數。 |
| `"cross"` | `length`、`width` | 兩者 **> 0** | 十字。`length` 是單臂長（從中心算），`width` 是臂寬。 |
| `"sector"` | `inner`、`outer`、`sweep` | `inner` **≥ 0**、`outer` **> 0** 且 **`inner` < `outer`**；`sweep` **> 0 且 ≤ 2π**（約 6.283） | 扇形環帶。`sweep` 是張角（弧度），以陣面 +x 方向為中線左右對開。 |

不放 `shape` 時，粒子從陣心附近（半徑 1.6 的散佈）生出。

```json
{ "rune": "shape", "shape": { "kind": "polygon", "sides": 5, "radius": 1.4 } }
{ "rune": "shape", "shape": { "kind": "star", "points": 6, "outer": 1.5, "inner": 0.6 } }
{ "rune": "shape", "shape": { "kind": "cross", "length": 1.6, "width": 0.3 } }
{ "rune": "shape", "shape": { "kind": "sector", "inner": 0.3, "outer": 1.6, "sweep": 3.14159 } }
```

```json
{ "rune": "shape", "shape": { "kind": "ring", "rInner": 1.0, "rOuter": 1.5 } }
```

### 6.2 `"radiate"`：往哪個方向散

| `mode` | 說明 |
|---|---|
| `"along-normal"` | 全部沿陣面法線同向前進（預設）。 |
| `"radial-outward"` | 各自從陣心往外放射。 |
| `"radial-inward"` | 各自往陣心收束（`radial-outward` 的反向）。 |
| `"tangential-swirl"` | 沿陣面切線走，也就是繞著陣心轉。 |

後三種都以粒子的**生成位置**決定方向，所以要搭配 `shape` 才看得出來；生在正中心的粒子沒有方向可言，會退回沿法線。

### 6.3 `"range"`：生成半徑的時間曲線

`expr` 是一段公式字串，逐時縮放粒子的生成偏移量。

```json
{ "rune": "range", "expr": "1 + sin(t*2)*0.5" }
```

### 6.4 `"style"`：粒子長什麼樣子

`billboard` 決定主效果粒子的告示板形態：

| `billboard` | 樣子 |
|---|---|
| `"square"` | 硬邊方塊（預設；不放 `style` 就是它）。 |
| `"soft-dot"` | 中心全亮、往外漸淡的軟光點。 |
| `"ring"` | 中空圓環。 |
| `"spark"` | 十字光芒。 |
| `"trail"` | 拖尾：沿粒子自己的速度方向拉長，速度愈快尾巴愈長。 |

只影響**施放主體**的粒子；「畫陣」階段的粒子永遠是硬邊方塊——畫出來的線要銳利。

```json
{ "rune": "style", "billboard": "soft-dot" }
```

`"trail"` 是唯一會讓系統多算東西的形態：陣裡只要有一個 `"trail"`，取樣就會多產出每顆粒子的速度（九欄輸出）；沒有的話輸出與這個形態存在之前逐位元相同，成本也完全一樣。拉長的方向與長度**完全由那顆粒子自己的速度導出**，不是可調參數——想要更長的尾巴，就把粒子催快一點（`trajectory` 的 `speed`，或一道推它的 `fields`）。

---

## 7. 公式字串語法（`expr`、`x`、`y`、`z`）

公式是**一行字串**，在載入時就會被剖析與檢查；寫錯會直接指出行列位置。

**變數與常數**

| 名稱 | 意義 |
|---|---|
| `t` | 秒數。行為層（`formula`）取的是**粒子自身年齡**；調變層（`bridge` 的曲線）取的是**施法經過秒數**。 |
| `life` | 粒子的歸一化壽命，0（剛生）→ 1（將死）。 |
| `pindex` | 粒子索引（整數，用來讓每顆粒子不一樣）。 |
| `pi` | 圓周率常數。 |

**函式**：`sin(a)`、`cos(a)`、`abs(a)`、`sqrt(a)`、`floor(a)`、`sign(a)`、`min(a,b)`、`max(a,b)`、`clamp(a,lo,hi)`。

**亂數**：`chan(N)`，N 必須是非負整數字面值。同一顆粒子、同一個通道編號永遠回同一個 `[0,1)` 的值——所以法術是決定論的、可重播的。

**運算子**（由高至低）：`^`（右結合）、前置 `-`、`*` `/`、`+` `-`。括號可用。
注意 `2^-3` 是語法錯誤（指數位置不吃前置負號），要寫成 `2^(-3)`。

**數字**：十進位整數或小數，可帶 `e` 指數；**不可**以小數點開頭、不可帶正負號（負號是運算子）。

**大小上限**：一條公式的語法樹最多 512 個節點。

---

## 8. 選配：`phases`、`fields`、`anchors`、`sigil` 與 `volume`

### 8.1 `phases`：生命週期分段（畫陣 → 收束 → 施放 → 消散）

```json
"phases": { "draw": 1.2, "converge": 0.6 }
```

| 鍵 | 限制 | 說明 |
|---|---|---|
| `draw` | **> 0** | 「畫陣」持續幾秒：這段時間會用粒子把陣的幾何**畫出來**（外框、每個有東西的槽位一圈、有符文的節點一小簇、中心一簇）。 |
| `converge` | ≥ 0 | 「蓄力」持續幾秒：陣畫好之後原地駐留這麼久，才真正施放。 |

不寫 `phases`（或寫 `null`）＝ 立刻施放，不畫陣。開啟後，主體的 `delay` 會自動再加上 `draw + converge`。

**魔法陣會一直留到法術結束**：陣被畫出來之後就待在原地，法術是從陣裡射出來的，兩者一起收場。陣不受 `fields`（力場）影響——力場吹得動法術，吹不動陣。

`bare-sigil.json` 是只有 `phases`、其他全空的例子——空陣也有輪廓。

### 8.2 `fields`：力場（陣級陣列）

在解析式軌跡之上疊加的位移層。`fields` 是陣列，每個元素用 `kind` 分六種：

| `kind` | 鍵 | 限制 | 說明 |
|---|---|---|---|
| `"gravity"` | `accel` | 3 個數字的陣列 `[x,y,z]` | 等加速度。 |
| `"attractor"` | `center`、`strength`、`softening` | `center` 為 `[x,y,z]`；`softening` **> 0** | 點吸引（`strength` 可負＝排斥）；`softening` 讓中心不發散。 |
| `"vortex"` | `center`、`axis`、`strength`、`falloff` | `axis` 為**非零**的 `[x,y,z]`；`falloff` ≥ 0 | 繞軸渦流；`falloff` 是隨距離的衰減，不可為負（力場不會越遠越強）。 |
| `"wind"` | `dir`、`strength`、`turbulence` | `dir` 為**非零**的 `[x,y,z]`；`turbulence` **≥ 0** | 定向的風，外加一層依位置而定的擾動。`turbulence` 為 0 就是純粹的等速吹拂。 |
| `"turbulence"` | `strength`、`scale` | `scale` **> 0** | 只有擾動沒有方向的亂流。`scale` 是空間尺度：越大，變化越緩、渦越大。 |
| `"spring"` | `center`、`k` | `k` **> 0** | 往 `center` 拉的線性回復力。與 `attractor` 不同：不隨距離衰減、中心不發散，粒子會**繞著中心來回振盪**而不是掉進去。 |

`wind` 與 `turbulence` 的擾動只看**位置**、不帶任何狀態，所以同一份法術每次施放都吹成一模一樣的形狀。

力場只作用於**施放階段**的粒子——畫陣階段的粒子要保持可讀，不被吹走。

`gravity-well.json` 示範前三種；`wuxing-seal.json` 示範 `wind` 與 `turbulence`，`yin-yang.json` 示範 `spring`。

### 8.3 `anchors`：發動點（法術從哪裡射出來）

```json
"anchors": [
  { "offset": [ 0.6, 0, 0], "normal": [0, 0, 1] },
  { "offset": [-0.6, 0, 0], "normal": [0, 0, 1] }
]
```

不寫 `anchors`（或寫 `null`）＝ **一個發動點，在施法者正前方**——這是所有既有法術的行為，一個位元都沒變。寫了，就是一道法術**同時從好幾個地方射出來**。

| 鍵 | 限制 | 說明 |
|---|---|---|
| `offset` | 3 個數字的陣列 `[x,y,z]` | 相對施法者的位置。座標是施法者面向的座標系：`x` = 右、`y` = 上、`z` = 正前方。 |
| `normal` | **非零**的 `[x,y,z]` | 這個發動點的初始面法線，也就是「這道往哪裡射」。`[0,0,1]` = 正前方。 |

三件要記得的事：

1. **粒子是平分的，不是複製的**。兩個發動點＝同樣多的粒子分成兩束，不是兩倍粒子。想要更強請調 `core.center.power`；加發動點不是作弊路徑（多加也照樣撞粒子上限）。
2. **陣只畫一次**。`phases` 畫出來的魔法陣在原點，不會跟著複製 N 份——發動點決定的是法術從哪裡出去，不是陣長什麼樣。
3. **上限 16 個**，而且**空陣列 `[]` 是錯誤**（要「沒有」請整個鍵刪掉或寫 `null`）——因為 `[]` 到底是「沒有發動點」還是「用預設那個」，看檔案是猜不出來的。

各發動點的符文與參數完全相同，只有位置與法線不同。想要「左手火、右手冰」，那是**兩張陣**，不是兩個發動點。

`twin-lance.json` 是雙發動點的例子：兩道雷矛從身體兩側平行射出。

### 8.4 `sigil`：陣自己的時間軸

```json
"sigil": { "linger": 2.5, "hold": true }
```

不寫 `sigil`（或寫 `null`）＝ §8.1 說的那樣：陣與法術一起收場，而且在等待期間每隔一小段就把自己重畫一次（讀起來像在呼吸）。兩個鍵都是選配，`"sigil": {}` 合法但什麼都不做。

| 鍵 | 限制 | 說明 |
|---|---|---|
| `linger` | −60 ≤ 值 ≤ 60（秒） | 陣的終點相對**法術終點**的位移。正 = 法術收了陣還留著；負 = 陣比法術先收。 |
| `hold` | `true` / `false`（預設 `false`） | `true` = **畫完即凍結**：陣照樣一點一點被畫出來，畫完之後外觀就不再變化。 |

三件要記得的事：

1. **陣一定會被畫完**。`linger` 再怎麼負，下界都是 `phases.draw`——「陣比法術先收」不會變成「陣沒畫完就沒了」。
2. **`linger` 會延長整道法術的生命週期**。宿主問「這道法術結束了嗎」，要等到陣也消失才會得到「是」——不會出現「法術已結束但畫面還有東西」。反過來，`linger` **不會**延後施放：法術本體的時間軸一格都沒動。
3. **凍結的陣仍然會轉**。自轉吃的是施法時鐘不是粒子年齡，所以 `hold` 凍的是外觀，不是動作。

`linger` 有上限是因為沒有上限的話，一個離譜的值會讓法術實質上永遠不結束，宿主就掛在那裡。

`lingering-seal.json` 兩個都用上：水元素的陣畫完就凍住，法術收了之後還留 2.5 秒。

### 8.5 `volume`：陣的立體堆疊

```json
"volume": {}
```

不寫 `volume`（或寫 `null`）＝ 陣維持單一平面，一個位元都不變。寫了——不管物件裡放什麼，甚至放空物件——就是「開」：陣沿法線堆疊成好幾層互相錯開的平行面。

三件要記得的事：

1. **存在即開關，內容被忽略**。`"volume": {}` 與 `"volume": {"anything": 1}` 效果完全相同——這個鍵目前沒有任何可調參數。
2. **層數由結構導出，不是你寫的數字**。實際堆幾層看外圈、夾層、內圈這五個槽位填了幾個：全空也會有下限 2 層，五槽全滿封頂在 5 層。
3. **每一層都是完整的一層，總量跟著層數上升**。堆疊不是把原本的粒子攤薄：每一層——包含四個節點與中心點——都拿到單層時的完整粒子數，所以五層的陣大約是單層的五倍。多出來的粒子照舊只由 `magic-validate` 的粒子上限管，沒有第二道閘門；反過來說，本來就快撞上限的陣再開 `volume` 是可能超支的。

`stacked-sigil.json` 是外圈、夾層、內圈五槽全填 + `phases` + `"volume": {}` 的例子：陣疊到層數的上限。

---

## 9. 檢查工具 `magic-validate`

```
cabal run magic-validate -- [--stats] PATH...
```

- `PATH` 可以是單一檔案，也可以是目錄（目錄下所有 `*.json` 依檔名排序全檢）。
- 每個檔案輸出一行 `OK <路徑>` 或 `FAIL <路徑>`，錯誤細節縮排在下一行。
- **離開碼 = 失敗的檔案數**（0 = 全過；64 = 用法錯誤），可直接放進 CI。
- 加 `--stats` 會在每個通過的檔案下印出六行：

```
OK assets/spells/grand-sigil.json
  budget    840 / 16384 particles
  emitters  10 [384, 96, 64, 64, 64, 64, 64, 12, 12, 16]
  lifetime  8.100s
  phases    draw 1.200s + converge 0.600s -> casting starts at 1.800s
  fields    0
  extent    (-14.794, -14.794, -14.794) .. (14.794, 14.794, 14.794)
```

| 行 | 意義 |
|---|---|
| `budget` | 這個法術會用掉的粒子總數 ／ 單一法術的上限。 |
| `emitters` | 發射器數量與各自的粒子數（索引 0 是施放主體，其餘是畫陣的幾何）。 |
| `lifetime` | 法術從施放到最後一顆粒子消失的總秒數。 |
| `phases` | 宣告的前奏長度，以及主體實際開始的時刻。 |
| `fields` | 力場數量。 |
| `extent` | 保守的世界座標包圍盒（施法者在原點、面向 +Y）——給宿主估算視野與裁切用。 |

---

## 10. 常見錯誤

| 訊息 | 原因 |
|---|---|
| `unsupported spell schema version N` | `version` 不是 1。 |
| `Unexpected "…" (line L, column C)` | JSON 語法壞了（少逗號、少括號）。位置就在訊息裡。 |
| `unknown rune tag "…" for the … slot; valid tags here: …` | `rune` 的值放錯槽位，或拼錯；訊息會列出該槽位合法的標籤。 |
| `ring needs rInner < rOuter` | 內半徑沒有小於外半徑。 |
| `… must be > 0` / `… must be >= 0` | 參數超出值域（見上表的「限制」欄）。 |
| `ring array has N layers; a ring holds at most 2` | `outer` 或 `inner` 放了超過 2 個元素。 |
| `axis must be a non-zero vector` | 渦流的 `axis` 是 `[0,0,0]`。 |
| `normal must be a non-zero vector` | 某個發動點的 `normal` 是 `[0,0,0]`，沒有面可以定。 |
| `expected at least one activation point` | `anchors` 寫成 `[]`；要「沒有」請刪掉這個鍵或寫 `null`。 |
| `too many activation points: N, the cap is 16` | `anchors` 超過 16 個。 |
| `invalid formula: …` | 公式字串語法錯誤；訊息含行列與合法名稱清單。 |
| `too many particles: this circle needs N, the cap is M` | `power` 太大。粒子數 = 256 × `power`。 |

---

## 11. 範例導覽（由淺入深）

全部在 `assets/spells/`。

**入門**

| 檔案 | 看什麼 |
|---|---|
| `empty.json` | 最小合法檔：`"circle": {}`，全部走預設。 |
| `square-burst.json` | 只有外圈形狀 + 放射 + 軌跡/包絡：最短的「有樣子」的法術。 |
| `spiral-spark.json` | `orbit` 軌跡 + 單一節點 `dir-bias`；示範省略 `bridge` 與部分 `nodes`。 |

**進階**

| 檔案 | 看什麼 |
|---|---|
| `ring-fire.json` | 完整四層：環形生成、`phase` 延遲、螺旋軌跡、火元素。 |
| `soft-bloom.json` | `style` 軟光點 + `phases`：畫陣是硬邊方塊、主效果是軟光點，一眼看出兩個批次。 |
| `pulse-ring.json` | 兩條曲線同時作用：`range` 讓生成半徑脈動，`amplify` 讓尺寸脈動。 |
| `converge-flame.json` | `converge` 收束曲線 `1 - life`：粒子邊飛邊向軸線收攏。 |
| `lissajous.json` | `formula` 自訂軌跡，三個分量各一條公式。 |

**完整**

| 檔案 | 看什麼 |
|---|---|
| `bare-sigil.json` | 只有 `phases`：空陣也會被畫出輪廓再收束。 |
| `grand-sigil.json` | `phases` + 全部槽位都有東西：畫陣階段會逐槽位畫筆畫。 |
| `lattice-seal.json` | `phases` + 雷元素 + 四節點：另一組槽位組合畫出另一個符文陣。 |
| `gravity-well.json` | `fields` 三種力場同時作用在施放階段的粒子上。 |
| `twin-lance.json` | `anchors` 兩個發動點：同一道法術從身體兩側平行射出，粒子平分不加倍。 |
| `lingering-seal.json` | `sigil` 陣自己的時間軸：`hold` 讓陣畫完就凍住，`linger` 讓它在法術收場後再留 2.5 秒。 |
| `stacked-sigil.json` | `volume` 立體堆疊：外圈、夾層、內圈五槽全填，陣沿法線疊成好幾層互相錯開的平行面。 |

**新語彙**

| 檔案 | 看什麼 |
|---|---|
| `wuxing-seal.json` | 金元素（加色）＋五邊形生成面＋切線放射＋`wave` 軌跡＋`wind`／`turbulence` 力場。 |
| `yin-yang.json` | 陰元素（alpha）＋扇形生成面＋向心收束＋`pulse` 軌跡＋`spring` 力場。 |
| `comet-trail.json` | `style` 拖尾：粒子沿自己的速度拉長。同時掛重力與渦流——尾巴會跟著場彎，因為速度算的是**渲染位置**的變化率，不是解析位置的。 |

> 上面兩張是**一組**：它們的混色模式相反（金加色、陰 alpha），所以把兩張疊起來施放時，同一畫面會同時出現兩種混色的批次——單獨施放任何一張都做不到這件事（見 §3.1 的說明）。

> **陣長什麼樣，由陣的內容決定**（func-spec 0016）。畫陣階段的幾何不是固定的同心圓，而是從這份 JSON 解出的魔法陣**自己**導出的：佔用了哪些槽位決定有幾層、半徑落在哪；魔法陣整體的結構摘要決定每一層用哪種筆畫（弧環／星形多邊形／輻條／刻度／玫瑰線／符文帶）、起始角與參數。所以同一份檔案永遠畫出同一個陣，改動任何一個符文都會畫出看得出差異的陣。這不需要任何新的 JSON 鍵——schema 一字未變。
>
> 例外照舊：外圈槽位放 `shape` 符文時，那一層改為預覽你畫的形狀（見 §3.1）。力場（`fields`）**不影響**陣的長相——力場是陣的物理環境，不是任何槽位的意義。

---

## 12. 機器可讀的 schema：`docs/spell.schema.json`

本文是給**人**看的；同一份格式另有一份給**機器**看的：`docs/spell.schema.json`，JSON Schema draft-07，直接放在 repo 裡。

- 編輯器（VS Code 等）指向它之後，寫法術檔時就有鍵名補全、標籤提示與即時錯誤標示。
- CI 或外部工具鏈可以拿它驗檔案的形狀，不必連上 Haskell。
- 產生指令 `cabal run magic-schema`；`cabal run magic-schema -- --check` 比對 repo 裡那份是否仍是產生器的輸出，不一致就 exit 1。

它描述的是**形狀**：有哪些鍵、每個鍵是什麼型別、哪些標籤合法、單一欄位的值域。**跨欄位的規則不在裡面**——內外半徑的大小關係、粒子上限這些仍然由 `magic-validate` 把關（§9）。所以「通過 schema」＝ 形狀正確，**不等於**「可以施放」；兩關都要過。

順帶一提，`magic-validate --json` 會把整趟檢查印成一份 JSON（逐檔的 path／ok／error，加 `--stats` 時附上數字），供編輯器與 CI 消費；不加 `--json` 時輸出與離開碼一個位元都沒變。想看一個法術「加起來是什麼」則用 `cabal run magic-inspect -- <檔案>`：預算、時間軸、逐發射器、批次一次印出來。

> 機械守護：`test/JsonSchemaSpec.hs` 斷言「schema 裡的標籤集合」與「本文以反引號加雙引號寫出來的標籤集合」**雙向相等**。所以本文與 schema 任一邊多寫或漏寫一個標籤，`cabal test` 會紅。
