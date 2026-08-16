#!/bin/sh
set -u

PASS=0
FAIL=0
WARN=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf 'WARN: %s\n' "$1"; WARN=$((WARN + 1)); }

check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then pass "command: $1"; else fail "command not found: $1"; fi
}

printf '%s\n' '=== secure-ipmi-terminal verify ==='

if [ "$(id -u)" -eq 0 ]; then
    pass "rootで検証を実行"
else
    fail "sudo tests/verify.sh で実行してください"
fi

if [ -r /etc/os-release ] && grep -q '^VERSION_ID="\?13' /etc/os-release; then
    pass "Debian 13"
else
    fail "Debian 13ではない"
fi

for cmd in ansible firefox-esr keepassxc nft tailscale pamu2fcfg pamtester; do
    check_cmd "$cmd"
done

if getent passwd sysadmin >/dev/null; then pass "sysadminユーザーが存在"; else fail "sysadminユーザーが存在しない"; fi
if getent passwd ipmi >/dev/null; then pass "ipmiユーザーが存在"; else fail "ipmiユーザーが存在しない"; fi

if id -nG sysadmin 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then pass "sysadminはsudoグループ所属"; else fail "sysadminがsudoグループにいない"; fi
if id -nG ipmi 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then fail "ipmiがsudoグループに所属している"; else pass "ipmiはsudoグループ非所属"; fi

for home in /home/sysadmin /home/ipmi; do
    mode=$(stat -c '%a' "$home" 2>/dev/null || echo missing)
    if [ "$mode" = "700" ]; then pass "$home mode=0700"; else fail "$home mode=$mode (expected 700)"; fi
done

if /usr/sbin/visudo -cf /etc/sudoers >/dev/null 2>&1; then pass "sudoers syntax"; else fail "sudoers syntax error"; fi
if grep -q 'timestamp_timeout=0' /etc/sudoers.d/99-secure-ipmi-terminal 2>/dev/null; then pass "sudo timestamp_timeout=0"; else fail "sudo timestamp_timeout設定なし"; fi

if grep -q '^WaylandEnable=false' /etc/gdm3/daemon.conf 2>/dev/null; then pass "GDM Wayland無効(Xorg)"; else fail "GDM WaylandEnable=falseがない"; fi

if systemctl is-enabled nftables >/dev/null 2>&1; then pass "nftables enabled"; else fail "nftables disabled"; fi
if nft list table inet secure_ipmi_terminal >/dev/null 2>&1; then pass "secure_ipmi_terminal nft table loaded"; else fail "nftables rules not loaded"; fi

if systemctl is-enabled tailscaled >/dev/null 2>&1; then pass "tailscaled enabled"; else fail "tailscaled disabled"; fi
if systemctl is-active tailscaled >/dev/null 2>&1; then pass "tailscaled active"; else fail "tailscaled inactive"; fi

if [ -f /etc/u2f_mappings ]; then
    pass "/etc/u2f_mappings exists"
    if grep -q '^sysadmin:' /etc/u2f_mappings && grep -q '^ipmi:' /etc/u2f_mappings; then pass "sysadmin/ipmi FIDO mapping exists"; else fail "FIDO mapping不足"; fi
else
    warn "/etc/u2f_mappings未作成（finalize前なら正常）"
fi

check_pam_policy() {
    policy_file=$1
    expected_user=$2

    if grep -Eq "^auth[[:space:]]+requisite[[:space:]]+pam_succeed_if\.so[[:space:]]+quiet[[:space:]]+user[[:space:]]+=[[:space:]]+$expected_user$" "$policy_file" 2>/dev/null && \
       grep -Eq '^auth[[:space:]]+sufficient[[:space:]]+pam_u2f\.so .*authfile=/etc/u2f_mappings .*origin=pam://secure-ipmi-terminal .*appid=pam://secure-ipmi-terminal .*pinverification=1 .*userverification=0 .*userpresence=1$' "$policy_file" 2>/dev/null; then
        pass "$policy_file FIDO2 policy content"
    else
        fail "$policy_file FIDO2 policy content invalid"
    fi
}

check_pam_include() {
    pamfile=$1
    include_name=$2

    if awk -v wanted="@include $include_name" '
        $0 == wanted { include_count++; include_line=NR }
        $0 ~ /^@include[[:space:]]+common-auth$/ && common_line == 0 { common_line=NR }
        /^# (BEGIN|END) secure-ipmi-terminal FIDO2$/ { legacy=1 }
        END {
            if (include_count != 1) exit 1
            if (include_line <= 0) exit 1
            if (common_line <= 0) exit 1
            if (include_line >= common_line) exit 1
            if (legacy == 1) exit 1
            exit 0
        }
    ' "$pamfile" 2>/dev/null; then
        pass "$pamfile FIDO2 include order"
    else
        fail "$pamfile FIDO2 include order invalid"
    fi
}

if [ -f /etc/pam.d/secure-ipmi-terminal-gdm ] && \
   [ -f /etc/pam.d/secure-ipmi-terminal-login ] && \
   [ -f /etc/pam.d/secure-ipmi-terminal-sudo ]; then
    pass "secure-ipmi-terminal PAM policy files exist"
    check_pam_policy /etc/pam.d/secure-ipmi-terminal-gdm ipmi
    check_pam_policy /etc/pam.d/secure-ipmi-terminal-login sysadmin
    check_pam_policy /etc/pam.d/secure-ipmi-terminal-sudo sysadmin
    check_pam_include /etc/pam.d/gdm-password secure-ipmi-terminal-gdm
    check_pam_include /etc/pam.d/login secure-ipmi-terminal-login
    check_pam_include /etc/pam.d/sudo secure-ipmi-terminal-sudo
else
    warn "secure-ipmi-terminal PAM policy未適用（finalize前なら正常）"
fi

if tailscale status >/dev/null 2>&1; then
    pass "Tailscale node authenticated"
else
    warn "Tailscale未ログイン。READMEの tailscale up を実行してください"
fi

if command -v systemd-cryptenroll >/dev/null 2>&1; then
    pass "systemd-cryptenroll available"
else
    fail "systemd-cryptenroll unavailable"
fi

check_luks_fido_boot() {
    crypttab_entry=$(awk '
        /^[[:space:]]*(#|$)/ { next }
        {
            nopts = split($4, opts, ",")
            for (i = 1; i <= nopts; i++) {
                if (opts[i] == "x-initrd.attach") {
                    print $1 "\t" $2 "\t" $3 "\t" $4
                    count++
                }
            }
        }
        END { if (count != 1) exit 1 }
    ' /etc/crypttab 2>/dev/null) || {
        fail "root LUKS crypttab entryを1件に特定できない"
        return
    }

    crypt_name=$(printf '%s\n' "$crypttab_entry" | cut -f1)
    crypt_source=$(printf '%s\n' "$crypttab_entry" | cut -f2)
    crypt_options=$(printf '%s\n' "$crypttab_entry" | cut -f4)

    case ",$crypt_options," in
        *,fido2-device=auto,*) pass "/etc/crypttab FIDO2 unlock設定" ;;
        *) fail "/etc/crypttabにfido2-device=autoがない" ;;
    esac

    case "$crypt_source" in
        UUID=*) crypt_device="/dev/disk/by-uuid/${crypt_source#UUID=}" ;;
        /dev/*) crypt_device="$crypt_source" ;;
        *)
            fail "未対応のcrypttab source: $crypt_source"
            return
            ;;
    esac
    crypt_device=$(readlink -f "$crypt_device" 2>/dev/null || true)

    if [ -n "$crypt_device" ] && cryptsetup luksDump --dump-json-metadata "$crypt_device" 2>/dev/null \
        | jq -e '[.tokens[]? | select(.type == "systemd-fido2")] | length > 0' >/dev/null 2>&1; then
        pass "root LUKS2 systemd-fido2 token"
    else
        fail "root LUKS2 systemd-fido2 tokenを確認できない"
    fi

    if command -v dracut >/dev/null 2>&1 && command -v lsinitrd >/dev/null 2>&1; then
        pass "dracut/lsinitrd available"
    else
        fail "dracut/lsinitrd unavailable"
        return
    fi

    if dpkg-query -W -f='${db:Status-Abbrev}' dracut 2>/dev/null | grep -q '^ii'; then
        pass "dracut installed"
    else
        fail "dracut package未導入"
    fi

    if dpkg-query -W -f='${db:Status-Abbrev}' initramfs-tools 2>/dev/null | grep -q '^ii'; then
        fail "initramfs-toolsがまだinstalled状態"
    else
        pass "initramfs-toolsはactive generatorではない"
    fi

    if [ -f /etc/dracut.conf.d/90-secure-ipmi-terminal.conf ] && \
       grep -q '^hostonly="yes"$' /etc/dracut.conf.d/90-secure-ipmi-terminal.conf && \
       grep -q '^force_add_dracutmodules+=" fido2 systemd-cryptsetup "$' /etc/dracut.conf.d/90-secure-ipmi-terminal.conf; then
        pass "secure-ipmi-terminal dracut設定"
    else
        fail "secure-ipmi-terminal dracut設定が不正"
    fi

    initrd="/boot/initrd.img-$(uname -r)"
    if [ ! -f "$initrd" ]; then
        fail "$initrd が存在しない"
        return
    fi

    listing=$(mktemp)
    if lsinitrd "$initrd" > "$listing" 2>/dev/null && \
       grep -Fq 'usr/bin/systemd-cryptsetup' "$listing" && \
       grep -Fq 'systemd-cryptsetup-generator' "$listing" && \
       grep -Fq 'libcryptsetup-token-systemd-fido2.so' "$listing" && \
       grep -Fq 'libfido2.so' "$listing"; then
        pass "initramfs FIDO2 boot components"
    else
        fail "initramfs FIDO2 boot components不足"
    fi
    rm -f "$listing"

    if lsinitrd -f /etc/crypttab "$initrd" 2>/dev/null | awk -v wanted="$crypt_name" '
        $1 == wanted {
            count++
            nopts = split($4, opts, ",")
            for (i = 1; i <= nopts; i++) {
                if (opts[i] == "fido2-device=auto") fido2 = 1
                if (opts[i] == "x-initrd.attach") initrd_attach = 1
            }
        }
        END {
            if (count != 1) exit 1
            if (fido2 != 1) exit 1
            if (initrd_attach != 1) exit 1
            exit 0
        }
    '; then
        pass "initramfs内crypttab FIDO2 unlock設定"
    else
        fail "initramfs内crypttab FIDO2 unlock設定が不正"
    fi
}

if command -v dracut >/dev/null 2>&1 || [ -f /etc/dracut.conf.d/90-secure-ipmi-terminal.conf ]; then
    check_luks_fido_boot
else
    warn "dracutによるLUKS FIDO2 boot未適用（finalize前なら正常）"
fi

printf '\nResult: PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
