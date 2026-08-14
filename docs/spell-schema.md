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

再加上兩個**選配**的陣級設定：`phases`（生命週期分段：先畫陣、再收束、才施放）與 `fields`（力場：重力／吸引子／渦流）。

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
    "fields": []
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
| `element` | `"neutral"` / `"fire"` / `"water"` / `"lightning"` | 決定顏色漸層與混色模式。`fire`、`lightning` 用加色（發光感），`neutral`、`water` 用一般 alpha 混色。 |
| `power` | 數字，**必須 > 0** | 粒子數 = `round(256 × power)`，下限 1。`power` 太大會編譯失敗（見 §9）。 |

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

用 `kind` 分三種：

| `kind` | 額外的鍵 | 說明 |
|---|---|---|
| `"forward"` | `speed`（數字） | 沿法線直線前進。 |
| `"spiral"` | `speed`、`radius`（**> 0**）、`freq` | 邊前進邊繞圈。`freq` 是每秒圈數。 |
| `"orbit"` | `radius`（**> 0**）、`freq` | 只繞圈不前進。 |

不放 `trajectory` 時的預設：`forward`，`speed` 4。

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

合法的 `rune` 值：`"shape"`、`"radiate"`、`"range"`。

### 6.1 `"shape"`：粒子從哪個圖形上生出來

`shape` 鍵下是一個物件，用 `kind` 分四種：

| `kind` | 額外的鍵 | 限制 |
|---|---|---|
| `"ring"` | `rInner`、`rOuter` | 兩者 **> 0** 且 **`rInner` < `rOuter`** |
| `"hollow-square"` | `size` | **> 0**（正方形邊長） |
| `"rect"` | `w`、`h` | 兩者 **> 0** |
| `"diamond"` | `size` | **> 0** |

不放 `shape` 時，粒子從陣心附近（半徑 1.6 的散佈）生出。

```json
{ "rune": "shape", "shape": { "kind": "ring", "rInner": 1.0, "rOuter": 1.5 } }
```

### 6.2 `"radiate"`：往哪個方向散

| `mode` | 說明 |
|---|---|
| `"along-normal"` | 全部沿陣面法線同向前進（預設）。 |
| `"radial-outward"` | 各自從陣心往外放射。 |

### 6.3 `"range"`：生成半徑的時間曲線

`expr` 是一段公式字串，逐時縮放粒子的生成偏移量。

```json
{ "rune": "range", "expr": "1 + sin(t*2)*0.5" }
```

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

## 8. 選配：`phases` 與 `fields`

### 8.1 `phases`：生命週期分段（畫陣 → 收束 → 施放 → 消散）

```json
"phases": { "draw": 1.2, "converge": 0.6 }
```

| 鍵 | 限制 | 說明 |
|---|---|---|
| `draw` | **> 0** | 「畫陣」持續幾秒：這段時間會用粒子把陣的幾何**畫出來**（外框、每個有東西的槽位一圈、有符文的節點一小簇、中心一簇）。 |
| `converge` | ≥ 0 | 「收束」持續幾秒：畫好的陣往中軸收攏，收完的瞬間才真正施放。 |

不寫 `phases`（或寫 `null`）＝ 立刻施放，不畫陣。開啟後，主體的 `delay` 會自動再加上 `draw + converge`。

`bare-sigil.json` 是只有 `phases`、其他全空的例子——空陣也有輪廓。

### 8.2 `fields`：力場（陣級陣列）

在解析式軌跡之上疊加的位移層。`fields` 是陣列，每個元素用 `kind` 分三種：

| `kind` | 鍵 | 限制 | 說明 |
|---|---|---|---|
| `"gravity"` | `accel` | 3 個數字的陣列 `[x,y,z]` | 等加速度。 |
| `"attractor"` | `center`、`strength`、`softening` | `center` 為 `[x,y,z]`；`softening` **> 0** | 點吸引（`strength` 可負＝排斥）；`softening` 讓中心不發散。 |
| `"vortex"` | `center`、`axis`、`strength`、`falloff` | `axis` 為**非零**的 `[x,y,z]`；`falloff` ≥ 0 | 繞軸渦流；`falloff` 是隨距離的衰減，不可為負（力場不會越遠越強）。 |

力場只作用於**施放階段**的粒子——畫陣階段的粒子要保持可讀，不被吹走。

`gravity-well.json` 同時示範了三種。

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
  budget    840 / 4096 particles
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
| `pulse-ring.json` | 兩條曲線同時作用：`range` 讓生成半徑脈動，`amplify` 讓尺寸脈動。 |
| `converge-flame.json` | `converge` 收束曲線 `1 - life`：粒子邊飛邊向軸線收攏。 |
| `lissajous.json` | `formula` 自訂軌跡，三個分量各一條公式。 |

**完整**

| 檔案 | 看什麼 |
|---|---|
| `bare-sigil.json` | 只有 `phases`：空陣也會被畫出輪廓再收束。 |
| `grand-sigil.json` | `phases` + 全部槽位都有東西：畫陣階段會逐槽位畫圈。 |
| `gravity-well.json` | `fields` 三種力場同時作用在施放階段的粒子上。 |
