---
id: B001
type: bugfix
title: integration-guide-contradictions
description: 整合指南殘留已推翻的執行緒與關閉敘述且守門假綠
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: [ADR-022]
related-feature: [F003, F004, F008]
---

# B001: 整合指南自我矛盾，而守門測試是假綠

## 症狀

`/arch-audit subsys host-runtime`(階段一閘門)的**高嚴重度發現 #1**。缺陷有兩層,第二層才是真正的問題。

**第一層:文件在教已被推翻的契約。** `docs/integration.md` 有三處敘述停留在 host-runtime 階段一之前的世界,而同一份文件的 §4.4 已經寫了相反的話。宿主讀到哪一句取決於他從哪一節開始讀:

| 位置 | 殘留的敘述 | 被誰推翻 | 現行契約 |
|---|---|---|---|
| `docs/integration.md:647`(§4.6 場景四件事表) | 「**一個 scene 一個執行緒**\|與 `PmSpell*` 同一條紀律,庫內仍然無鎖」 | [F004](../features/F004-thread-model.md) §4.4.2(`:553-585`) | 不同控制代碼可併發;同一控制代碼**不丟更新**、不保證順序;**每幀路徑**無鎖(不是「庫內無鎖」) |
| `docs/integration.md:866`(§6 不分語言的規則第 4 條) | 「一個 handle 一個執行緒。」 | 同上 | 同上 |
| `docs/integration.md:902`(§8 誠實清單) | 「**RTS 不可重啟**\|`pm_shutdown()` 之後不能再 `pm_init()`;一個 process 一份 GHC RTS」 | [F003](../features/F003-rts-config-init.md) §4.4(`:486`) | `pm_shutdown()` 是單向門,但**不再殺進程**:`pm_init_ex()` 回 `PM_ERR_STATE`、`pm_init()` 是無操作、其餘符號回哨兵 |

第三列尤其刺眼:[`F008-host-doc-corrections.md:39`](../features/F008-host-doc-corrections.md) 自己白紙黑字寫了「§8 的『RTS 不可重啟』歸 F003 的驗收改寫」,而 F003 只改了 §4.4,§8 那一列從頭到尾沒人動。

**第二層(本文件的重點):守門測試存在,但守不到。** `test/FFIContractSpec.hs:366-368`(F004 T6)已經有兩條 reject 斷言:

```haskell
mapM_
  (\needle -> (needle, isInfixOf' needle doc) `shouldBe` (needle, False))
  ["一個 handle 屬於一個執行緒", "庫內無鎖"]
```

比對的是**整句字面字串**。而殘留在文件裡的句子:

- `:866` 是「一個 handle 一個執行緒」——**少了「屬於」**
- `:647` 是「庫內仍然無鎖」——**多了「仍然」**

兩個字的差距,兩條斷言全部漏網。守門存在卻沒守到,比沒有守門更危險:下一輪的人看到 T6 綠著,會以為這件事已經被釘住了。階段一的 arch-audit 用同樣的手法抓出過三次假綠,這是第四次。

**影響範圍**:純文件與測試。沒有任何符號、`PM_ABI_VERSION`、`.def` 或綁定受影響;庫的實際行為一直是對的,錯的只有文件。

## 重現步驟

不需要執行環境,兩條 `grep` 就是最小重現:

```
$ grep -n "一個執行緒" docs/integration.md
647:| **一個 scene 一個執行緒** | 與 `PmSpell*` 同一條紀律,庫內仍然無鎖 |
866:4. 一個 handle 一個執行緒。

$ grep -n "不可重啟" docs/integration.md
902:| **RTS 不可重啟** | `pm_shutdown()` 之後不能再 `pm_init()`；一個 process 一份 GHC RTS |
```

而假綠的重現是:

```
$ cabal test --test-options='--match "keeps the integration guide"'
1 example, 0 failures        ← 三處矛盾都在,守門仍然是綠的
```

## 根因分析

**第一層的根因**是任務切分的接縫:F003 擁有 §4.4 的關閉語意、F004 擁有 §4.4.2 的執行緒模型、F008 擁有 §2.4/§4.2/§4.3/§5.4/§6/§8——但三者都只改「自己那一節」。§4.6 的表格、§6 的規則清單、§8 的限制表是**同一個語意的三個副本**,散在三個不同擁有者的章節裡,所以每個人都合理地認為那不是自己的責任(F008 甚至明確寫了「不動 §4.4 與 §8 的 RTS 條目,那是 F003 的」)。

**第二層的根因是斷言方法本身**:`FFIContractSpec` T6 用「整句字面字串」表達「這個說法不准回來」。字面字串釘住的是**一種寫法**,而語意有無限多種寫法——插一個副詞、換一個量詞、拿掉一個介詞,同一個錯誤說法就換了一件衣服走進來。這不是「那次剛好寫錯字串」,而是這個方法在原理上只能守住它抄下來的那一個句子;真正該守的是「§8 的限制表不得與 §4.4.x 的執行緒/關閉語意互相矛盾」這個**結構性**關係。

## 修復方向

1. **守門先加固,再修文件**(順序不可顛倒,否則無法證明守門真的會紅)。新增 `test/DocContradictionSpec.hs`,擁有三件事:
   - **正規化**:去掉全部空白(含 `\r`,本樹是 CRLF)與 Markdown 的 `*`/`` ` ``/`_` 強調符號,再比對。修飾詞(「仍然」「屬於」)因此不再是逃生門——它們改變的是句子的長度,不是被禁的**語意片段**。
   - **語意片段而非整句**:禁的是「一個執行緒」「單一執行緒」「執行緒所有」「不可重啟」「不能再pm_init」這種**短片段**。`一個 handle 一個執行緒`、`一個 scene 一個執行緒`、`一個 handle 屬於一個執行緒`、`handle 歸單一執行緒所有` 全部落在第一個片段上,不管中間塞什麼字。
   - **結構性斷言**:`無鎖`**每一次**出現都必須緊接在「每幀路徑」之後——這一條不靠禁字表,「庫內無鎖」「庫內仍然無鎖」「庫內部無鎖」一律紅。§8 的限制表裡凡提到 `pm_shutdown` 的列,必須同時提到 `PM_ERR_STATE`;凡提到執行緒的列,必須提到「不丟更新」或指回 §4.4.2。
   - 同時把 §4.4 / §4.4.2 的**正向錨點**釘住(「單向門」「PM_ERR_STATE」「不丟更新」「每幀路徑不取任何鎖」),避免有人靠刪掉權威敘述來讓測試變綠。
2. **`FFIContractSpec` T6 的兩條字面 reject 換成正規化片段比對**,從 `DocContradictionSpec` 匯入同一份禁用詞表,不留第二份定義——這是缺陷本體所在,不修就等於留著同一個坑。
3. **修文件三處**:§4.6 的表列、§6 的第 4 條、§8 的限制表列,全部改寫成 §4.4.2 / §4.4 的說法並回指章節。
4. **變異注入驗證**:把改好的句子逐一改回舊說法,確認守門真的變紅——這一步是本文件存在的理由,不做等於沒修。

**順帶處理**(使用者已裁決,屬同一次文件編輯):`docs/integration.md` 檔頭掛版本 **1.4**,記本輪 host-runtime 階段一的內容;frontmatter 的 `updated` 改 `2026-08-21`、`related-adr` 補 `adr-022`、`related-spec` 補 `func-0025`。

**明確不做**:不改任何符號、不動 `PM_ABI_VERSION` / `.def` / 綁定;不碰 `cbits/`;不修 arch-audit 的其他發現(§4.4.1/§4.4.2 的標題層級、`pm_scene_cast*` 的 `*out_id`、交叉引用失效),那些另案。

## TodoList

- [x] T1: 新增 `test/DocContradictionSpec.hs`(正規化 + 語意片段禁用表 + §8↔§4.4 結構性斷言),執行確認**修復前是紅的**  `dep: -`
- [x] T2: `FFIContractSpec` T6 的兩條字面 reject 改為匯入 T1 的禁用表比對,確認同樣**修復前是紅的**  `dep: T1`
- [x] T3: 修 `docs/integration.md:647`(§4.6 場景表的執行緒列)  `dep: T2`
- [x] T4: 修 `docs/integration.md:866`(§6 不分語言規則第 4 條)  `dep: T2`
- [x] T5: 修 `docs/integration.md:902`(§8 誠實清單的 RTS 列)  `dep: T2`
- [x] T6: 檔頭掛 1.4 版本沿革 + frontmatter 的 `updated` / `related-adr` / `related-spec`  `dep: T5`
- [x] T7: 變異注入驗證——三處逐一改回舊說法,確認守門變紅  `dep: T6`
- [x] T8: 完整 `cabal test` 綠  `dep: T7`

## 驗證方式

```
cabal test --test-options='--match "integration guide"'   # 重現測試:先紅後綠
cabal test                                                # 基線 1864 examples, 0 failures
```

變異注入的判準:把 `:647` 改回「庫內仍然無鎖」、`:866` 改回「一個 handle 一個執行緒」、`:902` 改回「RTS 不可重啟」,三次各自都要看到守門變紅;三次都紅才算守門真的在守。

## 修復紀錄

### 改了什麼

| 檔案 | 變更 |
|---|---|
| `test/DocContradictionSpec.hs`(新增) | 加固後的守門:4 條斷言,正規化 + 語意片段 + 結構性關係 + 正向錨點。匯出 `normalizeDoc`、`retiredClaims`、`guideOutsideAuthority` 給 `FFIContractSpec` 用 |
| `test/FFIContractSpec.hs` | F004 T6 的兩條字面 reject 換成匯入 `retiredClaims` 比對正規化後的文字;讀的是 `guideOutsideAuthority` |
| `docs/integration.md` | §4.6 表列、§6 第 4 條、§8 限制表列三處改寫;檔頭掛 1.4 版本沿革;frontmatter 的 `updated` / `related-adr` / `related-spec` |
| `particle-magic.cabal` | test-suite `other-modules` **只加一行** `DocContradictionSpec`(該區塊未重排) |

`docs/integration.md` 的 `git diff --stat` 是 **8 insertions / 7 deletions**——5 處編輯、其中版本沿革多出一行,沒有任何重排或重新格式化,CRLF 維持不變。

### 與「修復方向」的三處偏差

1. **正規化不能吃掉 `_`。** 第一版把 Markdown 的 `*`/`` ` ``/`_` 一起濾掉,結果 `pm_shutdown` 變成 `pmshutdown`、`PM_ERR_STATE` 變成 `PMERRSTATE`,§8↔§4.4 的結構性斷言與「不能再pm_init」這條禁用片段全部失效(第一次紅有 2 條是因為這個,不是因為缺陷)。本指南全篇用 `*` 做強調、`_` 只出現在 C 識別字裡,所以 `_` 保留。

2. **§4.4 與 §4.4.2 必須豁免。** §4.4.2 為了說明自己推翻了什麼,原文就寫著「以前這裡只寫『handle 歸單一執行緒所有』一句」——那是**正確的歷史引用**,不是殘留的契約。因此禁用片段掃的是「整份指南**扣掉** §4.4 與 §4.4.2」。這不是規則的漏洞,而是規則的精確版本:**全篇只有一個地方可以引用被推翻的說法,就是推翻它的那個地方**;其餘章節都是副本,副本還帶著舊說法就是本缺陷。豁免的兩節另由第 4 條正向錨點守住(而且斷言「這兩個章節標題必須存在」,改名不能靜默擴大豁免範圍)。

3. **多加了一條「無鎖必須被限定範圍」的結構性斷言。** 「無鎖」不能當禁用詞——那正是 §4.4.2 的承諾;錯的是**範圍**(庫內 vs 每幀路徑)。所以改成:文中**每一次**出現「無鎖」,前面四個字都必須是「每幀路徑」。這條不列舉任何寫法,「庫內無鎖」「庫內仍然無鎖」「庫內部依然是無鎖的」一律紅。

### 變異注入驗證(T7,`cabal test --match "agrees with itself" --match "keeps the integration guide"`)

逐一把修好的句子換成舊說法,跑守門,再還原;**六個變異全部被抓到**:

| 變異 | 注入的內容 | 結果 |
|---|---|---|
| M1 | §4.6 列還原成「一個 scene 一個執行緒 / 庫內仍然無鎖」 | **RED** 5 examples, 3 failures |
| M2 | §6 第 4 條還原成「一個 handle 一個執行緒。」 | **RED** 5 examples, 2 failures |
| M3 | §8 列還原成「RTS 不可重啟 / 之後不能再 `pm_init()`」 | **RED** 5 examples, 3 failures |
| M4 | 改成**舊守門原本比對的那一種寫法**「一個 handle 屬於一個執行緒,庫內無鎖」 | **RED** 5 examples, 3 failures |
| M5 | 改成**從來沒人寫過的第三種寫法**「每個 scene 歸單一執行緒所有 / 庫內部依然是無鎖的」 | **RED** 5 examples, 3 failures |
| M6 | 不還原舊說法,改成**刪掉 §4.4.2 的正向錨點**(「每幀路徑不取任何鎖」那句) | **RED** 5 examples, 1 failure |

M4 是這次修復的判準:那正是舊守門唯一抓得到的寫法,新守門一樣抓得到;M5 證明它抓的不再是「抄下來的那個句子」;M6 證明刪掉權威敘述不是變綠的捷徑。還原後 `git diff --stat docs/integration.md` 回到 8/7,檔案未受變異腳本污染。

### 測試結果(如實)

- 重現測試:修文件前 `4 examples, 4 failures`(其中 2 條是缺陷本體、2 條是上述偏差 1 的自傷),修完 `5 examples, 0 failures`(含 `FFIContractSpec` T6)。
- 完整套件:**1879 examples, 2 failures**。基線 1864 + 本文件 4 條 + 同時在跑的另一份 bugfix 新增的 11 條。
- **那 2 條失敗不屬於本修復**:`FFIStepPlanSpec:127` 與 `StepSpec:153`,兩者都是**同時進行中**的 `boundary-host/B001`(時步規劃器)的紅燈——`git status` 顯示 `src/boundary/Magic/Step.hs`、`test/StepSpec.hs`、`cbits/pm_init.c`、`cbits/pm_runtime.h`、`test/FFIRuntimeCapsSpec.hs` 由另一個 agent 持有且正在修改中,而本文件一個都沒碰。本修復涉及的檔案(`docs/integration.md`、`test/DocContradictionSpec.hs`、`test/FFIContractSpec.hs`)相關的測試全綠。

### 順帶給後續的建議

`docs/integration.md` 把同一個契約寫在 §4.x(正文)、§5.x(Unity)、§6(不分語言規則)、§8(限制表)四處,是本缺陷的**結構性成因**——本次只加固了執行緒與關閉這兩個契約的守門,其餘契約(粒子上限、六欄容量、`pm_free` 配對、混合模式)仍然只有人工紀律。若要根治,建議另走 `/enhance-design`:把 §6 與 §8 改成「指回正文章節」而不是複述,或把這種「摘要必須與正文一致」的關係做成通用的守門。屬另案,不在本次最小修復內。
