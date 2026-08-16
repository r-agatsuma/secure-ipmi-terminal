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
            exit !(
                include_count == 1 &&
                include_line > 0 &&
                common_line > 0 &&
                include_line < common_line &&
                legacy != 1
            )
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

printf '\nResult: PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
