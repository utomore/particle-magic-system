---
id: B002
type: bugfix
title: capability-zero-silently-dropped
description: 降級路徑把「依硬體決定」的 capability 請求無聲丟棄
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: []
related-adr: [ADR-022]
related-feature: [F003]
---

# B002: 降級路徑無聲丟棄 `capabilities == 0`

## 症狀

**觸發方式**:宿主自己先啟動 GHC RTS(Haskell 宿主,或自行呼叫 `hs_init`),再依標頭的建議寫法呼叫 `pm_init_ex`:

```c
PmConfig cfg = {0};
cfg.size = sizeof cfg;      /* 其餘全部維持 0 */
int rc = pm_init_ex(&cfg);
```

**預期行為**:`include/particle_magic.h:377` 定義 `capabilities == 0` 為「**依硬體決定**」,而同一份標頭的逐平台生效表(`:322-333`)在「RTS 已由宿主啟動」那一列把 capabilities 標為 `yes`,並在表下寫明「Nothing is ever ignored in silence」。所以這個請求應該被**實際套用**:capability 數變成機器的核心數。

**實際行為**:什麼都沒發生。`n_capabilities` 維持宿主啟動時的值(`hs_init` 沒帶 RTS 選項時是 1),`rc` 是 `PM_OK`——請求**既未套用、也未計入 `PM_ERR_STATE`**,無聲丟棄。

**影響範圍**:

- 違反 `design.md` C2.4 明文承諾「**不靜默忽略任何無法生效的設定**」;
- 違反標頭逐平台生效表對該列 capabilities 的 `yes` 宣告;
- 打到的正是**預設寫法**。標頭教宿主「Zero the whole struct, set size to sizeof(PmConfig), fill in what you care about」,一個不特別在意 capability 數的宿主寫出來的就是 `capabilities == 0`;
- 後果是這類宿主永遠停在 1 個 capability,平行取樣(ADR-0017)完全拿不到,而且沒有任何訊號告訴他為什麼。

**不影響**:非降級路徑(RTS 由本庫啟動)。該路徑早已把 0 正確翻成 `-N`,見下方「非降級路徑的一致性查證」。

## 重現步驟

缺陷落在 `pm_rt_start` 的降級分支,而狀態機規定**每個 process 只能初始化一次**,所以 in-process 測試對 `pm_init_ex` 只有一發子彈——`test/FFIRuntimeSpec.hs` 的 T2 已經用掉了,而且 T4(`:132`)只測**非零** capabilities。這正是這條分支長期無人看守的原因。因此重現分兩層:

**1. In-process(兩平台,進 `cabal test`)** — `test/FFIRuntimeCapsSpec.hs`

直接呼叫 `pm_rt_start` 委派該列的那個函式,把 RTS 先壓到 1 個 capability,再送一個歸零的 `PmConfig`:

```
setNumCapabilities 1
pm_runtime_apply_to_running(&cfg)   -- cfg 只填 size
getNumCapabilities                  -- 期望 = getNumProcessors
```

修復前:`expected: 16 / but got: 1`。

**2. Out-of-process(Linux only,`test/oop/run.sh`)** — 探針 `rts-prestarted-zero-caps`

`--all` 會為每個探針開一個**全新 child process**,所以這裡可以真的走完整條路:透過 dlsym 取得 `hs_init` 先把 RTS 啟起來(不帶 RTS 選項 → 1 個 capability),再呼叫真正的 `pm_init_ex`,然後用 dlsym 讀 `n_capabilities` 回來對帳。Linux 是唯一能這樣觀測的平台——Windows 的 `.def` 把 RTS 符號整個關在外面,該平台回 SKIP。

## 根因分析

`cbits/pm_init.c` 的降級分支(修復前約 `:292`):

```c
if (cfg != NULL) {
    if (cfg->capabilities != 0) {
        setNumCapabilities(cfg->capabilities);
    }
    if (cfg->nursery_bytes != 0
        || cfg->gc_mode != PM_GC_DEFAULT
        || (cfg->stats == PM_STATS_ON && !getRTSStatsEnabled())) {
        rc = PM_ERR_STATE;
    }
}
```

`capabilities` 是唯一一個「0 有語意」的欄位,而這段程式把它當成其他三個欄位一樣的「0 = 宿主沒填」來讀:

| 欄位 | 0 的意思 | `!= 0` 當守衛對不對 |
|---|---|---|
| `nursery_bytes` | 用 RTS 預設 | 對 |
| `gc_mode` | `PM_GC_DEFAULT` | 對 |
| `stats` | `PM_STATS_OFF` | 對 |
| `capabilities` | **依硬體決定**(標頭 `:377`) | **錯** |

於是 0 掉進兩個 `if` 之間的縫:第一個 `if` 不套用它,第二個 `if` 不提報它。

值得記一筆的是**非降級路徑沒有這個錯**:`pm_rt_build_opts`(`:197`)對 0 明確寫 `-N`(RTS 對「不帶數字的 `-N`」的定義就是依硬體決定),對 1 刻意不輸出(RTS 自己的預設就是 1)。也就是說專案裡對 0 的正確理解一直存在,只是降級路徑沒抄過去——同一個語意寫了兩次而不是共用一次,是這個缺陷得以存在的結構性原因。

## 修復方向

採**方向 (a):降級路徑上把 `capabilities == 0` 當成真實請求並實際套用**。

```c
want = cfg->capabilities;
if (want == 0) {
    want = getNumberOfProcessors();   /* RTS 自己回答 `-N` 用的同一個數 */
    if (want == 0) want = 1;
}
setNumCapabilities(want);
```

為什麼是 (a) 而不是 (b) 或 (c):

- **(b) 計入 `PM_ERR_STATE`** — 錯的。`PM_ERR_STATE` 的第二種意思是「這個欄位**沒辦法**生效」,但 capability 數在這一列**辦得到**(`setNumCapabilities` 就是為此存在,標頭的生效表也已經宣告 `yes`)。用 (b) 等於為了不違反 C2.4 而去謊報一個做得到的事做不到,而且會讓**每一個照建議寫法歸零 `PmConfig` 的宿主**都收到 `PM_ERR_STATE`,把這個錯誤碼稀釋成雜訊。
- **(c) 重新定義「未設定」與「依硬體決定」為兩個值** — 不採用。`PmConfig` 確實是本輪新增、尚未出貨的結構,改它技術上還來得及,但代價不成比例:
  - `capabilities == 0` 的語意寫在 **ADR-022 D1**(「capability 數(0 = 依硬體)」),改它要動 ADR 而不是改一個 bugfix;
  - `PmConfig` 的 **add-only 承諾**是「未來只加欄位,`size` 讓舊宿主繼續有效」。(c) 不加欄位,而是**改既有欄位的值域語意**——add-only 保護不到這種變更,舊編譯的宿主 `size` 仍然吻合、仍然被接受,但同一份位元組會被解讀成不同意思,這是 add-only 最不想發生的那種相容性破壞。就算現在還沒出貨,先立一個「欄位語意可以改」的前例也不划算;
  - 更要命的是它會讓「歸零 `PmConfig`」這個標頭教出來的預設寫法**不再等於依硬體決定**,而那正是宿主最常寫出來的東西。
  - (a) 修完之後,`capabilities` 的值域仍然是標頭原本那一行,兩條路徑講同一件事,ADR-022、標頭、實作三者一致,不需要任何 ADR 或標頭改動。

**測試接縫**:降級分支抽成 `cbits/pm_runtime.h` 的內部函式 `pm_runtime_apply_to_running`。這不是順手重構,是缺陷本身的一部分——「一個 process 只能初始化一次」使這條分支在 in-process 測試下不可列舉,B002 就住在沒人到得了的地方。抽出來之後每個 case 都能單獨驗。

該符號**不進 ABI**:不在 `include/particle_magic.h`、不在 `particle-magic-ffi.def`、不帶 `PM_EXPORT`(所以 `FFIContractSpec` 的公開符號清單不會算到它)。這跟 `pm_runtime_ready` 是同一個既有慣例——`pm_runtime.h` 本來就是為了讓 `pm_gate.c` 與 `pm_init.c` 共用狀態機而存在的內部標頭。`PM_ABI_VERSION` 不動,對外符號數不變。

`cfg == NULL`(`pm_init` 自己的呼叫)維持完全 no-op:那是唯一一個「宿主真的什麼都沒要求」的情況,`pm_init` 的凍結契約就是保守預設。

### 非降級路徑的一致性查證(不只修一半)

逐行讀過 `pm_rt_build_opts`(`cbits/pm_init.c:185-217`),確認與標頭敘述一致:

| `capabilities` | 送給 RTS 的選項 | 實際結果 | 與標頭 `:377` 一致? |
|---|---|---|---|
| 0 | `-N` | 依硬體核心數 | 一致 |
| 1 | (不輸出) | RTS 預設就是 1 | 一致 |
| 2..256 | `-N<n>` | n 個 | 一致 |

`-N0` 會讓 RTS 直接 abort 整個 process,所以 0 絕不能原樣轉成 `-N0`——現行寫法(0 → 不帶數字的 `-N`)正是對的。修完之後兩條路徑對 0 的答案是同一個數:一邊由 RTS 解析 `-N` 得到,一邊由本庫呼叫 RTS 自己的 `getNumberOfProcessors()` 得到,是同一個來源。

**不裁切到 `PM_MAX_CAPABILITIES`**:那個上界存在的理由是「宿主給的數字會直接進 RTS,壞值會 abort 整個 process」,而硬體自己的核心數不是宿主給的數字;非降級路徑的 `-N` 同樣不裁切,兩條路徑必須是同一件事。

## TodoList

- [x] T1: 撰寫重現缺陷的 in-process 測試 `test/FFIRuntimeCapsSpec.hs`,確認修復前為紅  `dep: -`
- [x] T2: 把降級分支抽成 `pm_runtime_apply_to_running`(內部符號,不進 ABI)  `dep: T1`
- [x] T3: 在該函式中把 `capabilities == 0` 套用為 `getNumberOfProcessors()`  `dep: T2`
- [x] T4: 補非零 capability 仍然生效的守衛測試(防過度修正)  `dep: T1`
- [x] T5: 補 `cfg == NULL` 仍為 no-op 的測試(`pm_init` 凍結行為)  `dep: T1`
- [x] T6: 補「無法生效欄位仍回報 `PM_ERR_STATE`、且不影響 capability 套用」的測試  `dep: T1`
- [x] T7: 查證非降級路徑對 0 的行為與標頭一致(見上表)  `dep: -`
- [x] T8: 新增 Linux end-to-end 探針 `rts-prestarted-zero-caps` 並同步 `test/oop/README.md`  `dep: T3`
- [x] T9: 變異注入驗證——把行為改回舊寫法,新測試必須變紅  `dep: T3`
- [x] T10: 完整 `cabal test`(Windows)與 Linux(WSL)各跑一次  `dep: T3`

## 驗證方式

```
cabal test --test-options='--match "host-runtime B002"'
cabal test
wsl -d Debian -e bash -lc 'cd ~/pm-smoke && cabal test'
wsl -d Debian -e bash -lc 'cd ~/pm-smoke && cabal build particle-magic-ffi && test/oop/run.sh'
```

判準:`FFIRuntimeCapsSpec` 四個 case 全綠;完整套件除既有的併行工項外無新增失敗;Linux 的 `rts-prestarted-zero-caps` 探針 PASS。

## 修復紀錄

依「修復方向」實作,無偏差。

**動到的檔案**

| 檔案 | 改了什麼 |
|---|---|
| `cbits/pm_init.c` | 降級分支抽成 `pm_runtime_apply_to_running`;`capabilities == 0` 改為套用 `getNumberOfProcessors()`;`pm_rt_start` 改成呼叫它 |
| `cbits/pm_runtime.h` | 宣告該內部函式,並寫明為何它不是 static(一個 process 只能初始化一次) |
| `test/FFIRuntimeCapsSpec.hs` | 新增:重現測試,轉綠後留為回歸測試(4 cases) |
| `particle-magic.cabal` | `other-modules` 加一行 `FFIRuntimeCapsSpec` |
| `test/oop/oop_smoke.c` | 新增探針 `rts-prestarted-zero-caps`(Linux end-to-end,Windows SKIP) |
| `test/oop/README.md` | Probes 表格補該探針(`OopSmokeSpec` 雙向對帳) |

**沒動到的**:`include/particle_magic.h`(標頭原本就是對的,錯的是實作)、`PM_ABI_VERSION`、`particle-magic-ffi.def`、對外符號數、`docs/integration.md`、arch-audit 的其他發現。

**變異注入驗證(T9)**:把 `pm_runtime_apply_to_running` 內的套用改回舊寫法 `if (want != 0) setNumCapabilities(want);`,重建後執行 `--match "host-runtime B002"`:

```
4 examples, 2 failures
  applies capabilities = 0 as 'follow the hardware' instead of dropping it
       expected: 16 / but got: 1
  reports the fields this row cannot honour, with or without a capability count
       expected: 16 / but got: 1
```

還原後同一條命令 `4 examples, 0 failures`。新測試確實咬得到這一行,不是假綠。

同一個變異也在 Linux 上對 out-of-process 探針做過一次(重建 `libparticle-magic-ffi.so` 後 `test/oop/run.sh`):

```
變異版:rts-prestarted-zero-caps: fail -- n_capabilities is still 1: capabilities = 0
        means 'follow the hardware' (particle_magic.h), and a request that is neither
        applied nor reported is the silent drop C2.4 forbids
還原後:rts-prestarted-zero-caps: pass -- runtime already up, capabilities = 0:
        applied as 16 (the machine's own count), reported PM_OK, library usable
        oop-smoke: 8 passed, 0 failed, 1 skipped, 0 pending
```

也就是說,in-process 與 end-to-end 兩層各自獨立地先紅後綠。

**測試結果**

| 平台 | 命令 | 結果 |
|---|---|---|
| Windows x86_64 | `cabal test` | `1879 examples, 0 failures` |
| Windows x86_64 | `--match "host-runtime B002"` | `4 examples, 0 failures` |
| Linux x86_64 (WSL Debian) | `cabal test` | `1879 examples, 0 failures, 9 pending` |
| Linux x86_64 (WSL Debian) | `--match "host-runtime B002"` | `4 examples, 0 failures` |
| Linux x86_64 (WSL Debian) | `--match "out-of-process load smoke"` | `5 examples, 0 failures` |
| Linux x86_64 (WSL Debian) | `test/oop/run.sh` | `8 passed, 0 failed, 1 skipped`(`firewall` 需 poison build) |

**順手發現、未在本案處理**(建議另案):

1. 標頭 `:332` 那句「On that last row pm_init_ex answers PM_ERR_STATE」寫得比實際嚴格。實作(修復前後皆然)是「**只有當某個欄位真的無法套用時**才回 `PM_ERR_STATE`」,所以一個歸零的 `PmConfig` 在該列拿到的是 `PM_OK`。這是既有敘述的鬆散處,不是本案造成的,而且 `docs/integration.md` 正由另一個 agent 修改中,故不在此動它。
2. WSL 的鏡像用 `tar` 從 Windows 工作樹複製,而本專案 `core.autocrlf=true`(repo 存 LF、Windows 檢出 CRLF),所以鏡像裡的 golden 檔帶著 CRLF,`SpaceBoundsSpec` 在 Linux 上會因為每行多一個 `\r` 而紅——數值逐項相同。真正的 Linux CI 是 `git` 檢出、拿到 LF,不受影響。本次驗證前把該 golden 正規化成 LF。這是鏡像流程的既有陷阱,與本案無關,但值得寫進 WSL smoke 的作法裡。
3. 「0 = 依硬體決定」這個語意目前寫在兩個地方(`pm_rt_build_opts` 的 `-N` 與 `pm_runtime_apply_to_running` 的 `getNumberOfProcessors()`)。兩者現在一致,但仍是同一條規則的兩份表述;若日後再加第三條路徑,值得走 `/enhance-design` 收斂成一處。

## 待確認假設

- A1: 重現測試打的是抽出來的內部函式 `pm_runtime_apply_to_running` 而非 `pm_init_ex` 本身 → 採取:接受這個接縫,理由是狀態機每 process 只允許一次初始化,in-process 無法列舉該分支;並用 Linux 的 `rts-prestarted-zero-caps` 探針補上真正的 end-to-end 對帳 → 影響:若日後決定內部標頭不得再增符號,這條測試要改走純 out-of-process,in-process 覆蓋率會退回今天的 T4 水準。
- A2: `capabilities == 0` 在降級路徑不裁切到 `PM_MAX_CAPABILITIES` → 採取:與非降級路徑的 `-N` 對齊,不裁切 → 影響:若日後認定核心數超過 256 的機器也該受該上界約束,兩條路徑要一起改,並回頭修標頭對 `PM_MAX_CAPABILITIES` 的敘述。
