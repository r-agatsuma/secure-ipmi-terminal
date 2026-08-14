# secure-ipmi-terminal

家庭内のBMC/IPMI管理専用端末を、Debian 13 + Ansibleで再構築可能にするためのCookbookです。

主目的は、ASRock Rack ROMED8-2T等のHTML5 KVMに対して、KeePassXC Auto-Typeで長いパスフレーズを正確に入力できる管理端末を作ることです。端末内の可用性・データ救出は重視せず、壊れたらDebianを再インストールしてこのリポジトリから復元する前提です。

## 設計方針

- OS: Debian 13 (trixie) amd64
- Desktop: GNOME on Xorg
  - KeePassXC Auto-Typeを使うためWaylandを採用しない
  - X11の同一セッション内アプリ間隔離の弱さは、この専用端末では許容する
- `ipmi`ユーザー
  - GUI/Firefox/KeePassXC/Terminal/SSH用
  - `sudo`なし
- `sysadmin`ユーザー
  - OS管理専用
  - TTYログインのみ
  - `sudo`あり
- root
  - パスワードログイン禁止
- 認証
  - `ipmi` GUI login: YubiKey FIDO2 PIN + touch
  - `sysadmin` TTY login: YubiKey FIDO2 PIN + touch
  - `sysadmin` sudo: YubiKey FIDO2 PIN + touch
  - sudo認証キャッシュは無効 (`timestamp_timeout=0`)
- Disk: LUKS2 + YubiKey FIDO2 x2 を最終目標とする
  - 端末内データの救出は要件にしない
  - ただしroot LUKSのFIDO2 boot unlockはDebianのinitramfs実装差があるため、初期パスフレーズは実機でFIDO2起動確認が完了するまで削除しない
- Tailscale
  - native `tailscaled`
  - 既存OpenWrt subnet routerの経路を受け取るクライアント
  - `accept-routes=true`
  - `shields-up=true`
  - subnet routeの広告はしない
- Firewall
  - nftablesによる単純なstateful host firewall
  - inbound原則drop / outbound許可
  - 厳格なegress whitelistは行わない
- 設定管理: local Ansible
- 秘密情報はGitに保存しない

## リポジトリ

GitHub上では以下を想定します。

```text
https://github.com/r-agatsuma/secure-ipmi-terminal
```

ZIPを展開して新規repositoryへ初回pushする場合の例です。GitHub側で空の`secure-ipmi-terminal` repositoryを作成してから実行します。

```bash
cd secure-ipmi-terminal
git init
git add .
git commit -m "feat: initial secure IPMI terminal cookbook"
git branch -M main
git remote add origin https://github.com/r-agatsuma/secure-ipmi-terminal.git
git push -u origin main
```

## 0. Debianの入手

Debian公式のstable installerから **Debian 13 (trixie) amd64 netinst** を取得します。

- https://www.debian.org/distrib/netinst
- https://www.debian.org/releases/stable/amd64/

バージョン番号は13.xの最新ポイントリリースを使います。特定の13.xへ固定しません。

## 1. Debian初回インストール

Debian Installerでは以下を基準にします。

### Firmware/UEFI

- UEFI bootを使用
- Secure Bootは原則ONのまま試す
- 外部メディアからのboot順序等は導入後に必要に応じてBIOS側で制限する

### ユーザー

root用パスワードは**空欄**にします。Debian Installerではこの方法でrootのパスワードログインを無効化し、最初に作る一般ユーザーからsudoを利用する構成にします。

最初のユーザーは以下で固定します。Debian Installerでは `admin` は予約ユーザー名のため、このCookbookでは `sysadmin` を使用します。

```text
username: sysadmin
```

`sysadmin`には初回構築用の一時UNIXパスワードを設定します。このパスワードはFIDO2認証の動作確認後にロックします。

### Disk

Installerの暗号化構成を使い、root filesystemをLUKSで暗号化します。家庭用専用端末なので、複雑なpartition分割は不要です。

初回は必ず一時LUKSパスフレーズを設定してください。YubiKey FIDO2による**実際のboot unlock確認が済むまで、このkeyslotを削除しない**でください。

### Software selection

最低限以下を選択します。

- GNOME
- standard system utilities

SSH serverは不要です。この端末はSSHクライアントとして使い、Tailscale SSH serverも有効化しません。

インストール完了後、ネットワーク接続を確認します。

## 2. リポジトリを取得

`sysadmin`でログインします。

```bash
sudo apt update
sudo apt install -y git ansible

git clone https://github.com/r-agatsuma/secure-ipmi-terminal.git
cd secure-ipmi-terminal
```

AnsibleはPAMとの相性を単純にするため、playbook内部でsudoするのではなく**Ansibleプロセス全体をsudoで起動**します。

## 3. bootstrapを適用

```bash
sudo ansible-playbook bootstrap.yml
```

主に以下が適用されます。

- `ipmi`ユーザー作成
- Firefox ESR / KeePassXC / GNOME on Xorg / Terminal / OpenSSH client
- pam-u2f関連ツール
- `sysadmin`のみsudo可能
- sudo `timestamp_timeout=0`
- nftables
- Tailscale公式APT repository + native tailscaled

反映後、一度再起動します。

```bash
sudo reboot
```

## 4. Tailscaleを手動登録

Tailscaleのnode認証情報はGit/Ansibleに保存しません。

```bash
sudo tailscale up
sudo tailscale set --accept-routes=true --shields-up=true
```

確認します。

```bash
tailscale status
```

既存OpenWrtが広告しているIPMI/BMC subnetへ到達できることを確認してください。

この端末では以下を行いません。

- `--advertise-routes`
- exit node化
- Tailscale SSH server

## 5. PAM用YubiKeyを2本登録

FIDO2 credentialのoriginはhostname変更で壊れないよう、以下に固定します。

```text
pam://secure-ipmi-terminal
```

まずYubiKey Aを挿します。

```bash
umask 077
pamu2fcfg -u sysadmin -o pam://secure-ipmi-terminal -i pam://secure-ipmi-terminal -N | tr -d '\n' > /tmp/sysadmin.u2f
pamu2fcfg -u ipmi  -o pam://secure-ipmi-terminal -i pam://secure-ipmi-terminal -N | tr -d '\n' > /tmp/ipmi.u2f
```

YubiKey Aを抜き、YubiKey Bを挿します。

```bash
printf ':' >> /tmp/sysadmin.u2f
pamu2fcfg -u sysadmin -o pam://secure-ipmi-terminal -i pam://secure-ipmi-terminal -N -n | tr -d '\n' >> /tmp/sysadmin.u2f
printf '\n' >> /tmp/sysadmin.u2f

printf ':' >> /tmp/ipmi.u2f
pamu2fcfg -u ipmi -o pam://secure-ipmi-terminal -i pam://secure-ipmi-terminal -N -n | tr -d '\n' >> /tmp/ipmi.u2f
printf '\n' >> /tmp/ipmi.u2f
```

root管理のmapping fileへ配置します。

```bash
cat /tmp/sysadmin.u2f /tmp/ipmi.u2f | sudo tee /etc/u2f_mappings >/dev/null
sudo chown root:root /etc/u2f_mappings
sudo chmod 0600 /etc/u2f_mappings
rm -f /tmp/sysadmin.u2f /tmp/ipmi.u2f
```

秘密鍵はYubiKeyから出ません。`/etc/u2f_mappings`はPAMが利用するcredential mappingです。

## 6. FIDO2 PAM設定を投入（まだパスワードはロックしない）

```bash
sudo ansible-playbook finalize.yml
```

この時点では以下のPAM policyが入りますが、`sysadmin`の一時UNIXパスワードはまだ残っています。

- `gdm-password`: `ipmi`のみ + FIDO2 PIN/touch
- `login`: `sysadmin`のみ + FIDO2 PIN/touch
- `sudo`: `sysadmin`のみ + FIDO2 PIN/touch

FIDO2が成功すれば従来のpassword stackへ進まず認証成功します。FIDO2が失敗した場合は、最終ロック前であれば従来のUNIX passwordへfallbackできます。

## 7. PAM認証を検証

現在の`sysadmin`セッションは閉じないでください。

まずPAM単体で確認します。

```bash
sudo pamtester login sysadmin authenticate
sudo pamtester gdm-password ipmi authenticate
sudo pamtester sudo sysadmin authenticate
```

いずれもYubiKey PIN + touchで成功することを確認します。

続いてsudo自体を確認します。

```bash
sudo -k
sudo true
```

FIDO2 PIN + touchが要求されることを確認します。

### Xorg確認

`ipmi`でGUIログイン後、Terminalで以下を実行します。

```bash
echo "$XDG_SESSION_TYPE"
```

期待値:

```text
x11
```

`sysadmin`はGDMからGUIログインできないことも確認します。

## 8. UNIX passwordを最終ロック

上記が全て成功した場合だけ実行します。

念のため、実行前に別TTYで一時的なroot shellを開いたままにしておくと、PAM設定ミス時に復旧しやすくなります。

```bash
sudo -i
```

そのroot shellは閉じず、別の`sysadmin`端末から以下を実行します。

```bash
cd ~/secure-ipmi-terminal
sudo ansible-playbook finalize.yml -e lock_passwords=true
```

これによりroot/sysadmin/ipmiのUNIX passwordをlockします。

ロック後、再度以下を確認します。

```bash
sudo -k
sudo true
```

別TTYでも`sysadmin` + FIDO2 PIN/touchでログインできることを確認し、問題がなければ一時root shellを閉じます。

## 9. LUKS2へYubiKey FIDO2を登録

**この工程は初期repoでは自動化しません。** boot/initramfsを壊した場合の影響が大きく、実機を見ながら行うためです。

まず対象LUKSデバイスを確認します。

```bash
lsblk -f
cat /etc/crypttab
sudo systemd-cryptenroll --list-devices
```

対象を例として `/dev/nvme0n1p3` とした場合、YubiKey A/Bを1本ずつ登録します。

```bash
sudo systemd-cryptenroll --fido2-device=auto /dev/nvme0n1p3
```

2本目へ差し替えてもう一度実行します。

```bash
sudo systemd-cryptenroll --fido2-device=auto /dev/nvme0n1p3
```

### 重要: Debianのroot initramfs

`systemd-cryptenroll`はLUKS2へFIDO2 tokenを登録できますが、Debian Installer標準のroot暗号化は`cryptsetup-initramfs`系のearly bootを使う場合があり、systemdの`fido2-device=`をそのままboot時に利用できるとは限りません。

そのため初回構築では**一時LUKSパスフレーズを残したまま再起動し、FIDO2でroot unlockできるかを実機確認**します。

FIDO2 promptが出ない場合は、その場で構成を確認して修正します。この状態でも一時パスフレーズが残っているためboot不能にはなりません。

FIDO2でYubiKey A/B双方のboot unlockを確認してから、初期パスフレーズkeyslotを削除します。削除作業は実機確認後に行います。

## 10. ROMED8 Auto-Typeを検証

`ipmi`でGNOME/Xorgへログインします。

1. KeePassXCにテスト用の長い文字列を登録
2. Firefox ESRでROMED8-2TのHTML5 KVMを開く
3. remote host側で入力結果を確認できる画面を用意
4. KeePassXC Auto-Typeを実行
5. 長い文字列で欠落・配列違い・記号化けがないことを確認

Auto-Type delayの調整が必要な場合は、設定をその場で試し、安定値が分かったらGitHub Issueを作成してPRでCookbookへ反映します。

ROMED8のLUKS unlock用途では速度より確実性を優先します。

## 11. 全体検証

```bash
sudo tests/verify.sh
```

`WARN`は構築途中では許容します。最終状態では理由の分からない`FAIL`を残さないでください。

手動確認項目:

- `ipmi` GUI login: FIDO2 PIN + touch
- `sysadmin` TTY login: FIDO2 PIN + touch
- `sysadmin` sudo: 毎回FIDO2 PIN + touch
- `ipmi`: sudo不可
- `sysadmin`: GDM GUI login不可
- `echo $XDG_SESSION_TYPE` = `x11`
- Tailscale経由でOpenWrt配下のBMCへ接続可能
- Tailnetから管理端末への不要なincoming connectionがshields-upで拒否される
- ROMED8 HTML5 KVMへのAuto-Typeが安定する
- LUKS FIDO2 boot unlockはYubiKey A/B双方で確認する

## 日常運用・設定変更

通常の変更フローは以下です。

```text
問題/改善点を発見
  ↓
GitHub Issue
  ↓
設定変更branch
  ↓
Pull Request
  ↓
merge
  ↓
端末でgit pull
  ↓
Ansible再適用
  ↓
verify
```

端末では以下の形で更新します。

```bash
cd ~/secure-ipmi-terminal
git pull
sudo ansible-playbook bootstrap.yml
sudo ansible-playbook finalize.yml
sudo tests/verify.sh
```

`sudo`は毎回FIDO2認証されますが、`ansible-playbook`自体をrootとして起動するため、playbook内の各taskごとにFIDO2を要求されることはありません。

## Gitに入れないもの

以下はcommitしません。

- KeePassXC database (`*.kdbx`)
- LUKS passphrase/recovery情報
- Tailscale auth key
- SSH private key
- YubiKeyのPIN
- その他credential/token

このリポジトリは、秘密情報を含めなければ公開repositoryでも成立する構成を目標にしています。

## 参考

- Debian: https://www.debian.org/
- Debian Packages: https://packages.debian.org/trixie/
- Yubico pam-u2f: https://developers.yubico.com/pam-u2f/
- systemd-cryptenroll: https://www.freedesktop.org/software/systemd/man/latest/systemd-cryptenroll.html
- Tailscale Linux client preferences: https://tailscale.com/docs/features/client/manage-preferences
- Tailscale Debian packages: https://pkgs.tailscale.com/stable/
