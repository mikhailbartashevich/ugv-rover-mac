import Foundation

/// A Wi‑Fi network the rover can see.
public struct RoverWiFiNetwork: Identifiable, Hashable, Sendable {
    public var id: String { ssid }
    public let ssid: String
    /// 0–100.
    public let signal: Int
    /// As NetworkManager reports it, e.g. "WPA2", "WPA2 WPA3", "" for open.
    public let security: String
    public let inUse: Bool

    public init(ssid: String, signal: Int, security: String, inUse: Bool) {
        self.ssid = ssid
        self.signal = signal
        self.security = security
        self.inUse = inUse
    }

    public var isOpen: Bool { security.isEmpty || security == "--" }

    /// NetworkManager key management: plain WPA2 (and WPA2/WPA3 mixed) take "wpa-psk";
    /// a WPA3-only network needs "sae".
    public var keyMgmt: String {
        let s = security.uppercased()
        return s.contains("WPA3") && !s.contains("WPA2") && !s.contains("WPA1") ? "sae" : "wpa-psk"
    }
}

/// A Wi‑Fi profile saved on the rover (NetworkManager connection).
public struct RoverSavedNetwork: Hashable, Sendable {
    public let name: String
    public let ssid: String
    public let priority: Int
    /// The rover's own hotspot (AccessPopup) rather than a network it joins.
    public let isAccessPoint: Bool
}

/// What the rover reports about its Wi‑Fi.
public struct RoverWiFiSurvey: Sendable {
    public var hostname: String?
    public var currentSSID: String?
    public var currentIsAccessPoint = false
    public var ipv4: String?
    public var nearby: [RoverWiFiNetwork] = []
    public var saved: [RoverSavedNetwork] = []

    public func isSaved(_ ssid: String) -> Bool {
        saved.contains { $0.ssid == ssid && !$0.isAccessPoint }
    }
}

/// Outcome the rover writes after trying the new network (read back later when it is
/// reachable again, e.g. after it fell back to the old one).
public struct RoverWiFiResult: Equatable, Sendable {
    public let ok: Bool
    public let ssid: String
    /// IP on success, NetworkManager's error on failure.
    public let detail: String
}

/// Bash scripts that inspect and change the rover's Wi‑Fi through NetworkManager.
///
/// Rules: existing profiles are never deleted (only a profile this switch created, if it
/// fails). The new network gets the highest autoconnect priority, so it wins on boot,
/// while every other profile stays as a fallback. If joining fails, the old profile is
/// restored and brought back up; AccessPopup's hotspot is the last resort.
public enum RoverWiFiScript {
    public static let curMarker = "__UGV_CUR__"
    public static let netMarker = "__UGV_NET__"
    public static let savedMarker = "__UGV_SAVED__"
    public static let resultMarker = "__UGV_RESULT__"
    public static let switchMarker = "__UGV_SWITCH__"

    /// Failure reasons the switch script prints after the FAIL marker.
    public static let failSudo = "sudo"
    public static let failAlreadyOn = "already-on"

    /// Shared prelude: `e MARKER payload` prints the payload base64-encoded (safe for any
    /// SSID), `DEV` is the Wi‑Fi device, `w` reads a field of a profile by UUID.
    private static let prelude = """
    e() { printf '%s %s\\n' "$1" "$(printf '%s' "$2" | base64 | tr -d '\\n')"; }
    w() { nmcli -e no -g "$1" connection show uuid "$2" 2>/dev/null | head -1; }
    DEV=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
    DEV=${DEV:-wlan0}
    CUR=$(nmcli -t -e no -f UUID,DEVICE connection show --active 2>/dev/null | sed -n "s/:$DEV\\$//p" | head -1)
    wifi_profiles() { nmcli -t -e no -f UUID,TYPE,NAME connection show 2>/dev/null | sed -n 's/^\\([^:]*\\):802-11-wireless:\\(.*\\)$/\\1 \\2/p'; }
    """

    /// Prints the current network, the networks in range and the saved profiles.
    public static func survey() -> String {
        """
        \(prelude)
        s() { sudo -n "$@" 2>/dev/null || "$@"; }
        e \(curMarker) "$(hostname)\t$(w 802-11-wireless.ssid "$CUR")\t$(w 802-11-wireless.mode "$CUR")\t$(nmcli -g IP4.ADDRESS device show "$DEV" 2>/dev/null | head -1)"
        L=$(s nmcli -t -e no -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan yes ifname "$DEV" 2>/dev/null) || L=$(nmcli -t -e no -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan no ifname "$DEV" 2>/dev/null)
        printf '%s\\n' "$L" | while IFS= read -r l; do [ -n "$l" ] && e \(netMarker) "$l"; done
        wifi_profiles | while read -r u n; do
          e \(savedMarker) "$n\t$(w 802-11-wireless.mode "$u")\t$(w 802-11-wireless.ssid "$u")\t$(w connection.autoconnect-priority "$u")"
        done
        rm -f "$0"
        echo "\(ProvisionScript.okMarker)"
        """
    }

    /// Saves `ssid` on the rover (updating its profile if one exists), then — detached, so
    /// it survives the terminal and the Wi‑Fi dropping — switches to it, rolling back to
    /// the current network if that fails. The outcome goes to `<tmp>/ugv_wifi_result`.
    /// `tmp` and `delay` exist for tests.
    public static func makeSwitch(ssid: String, password: String, keyMgmt: String = "wpa-psk",
                                  sudoPassword: String, tmp: String = "/tmp", delay: Int = 3) -> String {
        """
        SSID=\(Shell.quote(ssid))
        PASS=\(Shell.quote(password))
        KM=\(Shell.quote(keyMgmt))
        PW=\(Shell.quote(sudoPassword))
        T=\(Shell.quote(tmp))
        s() { if [ -n "$PW" ]; then printf '%s\\n' "$PW" | sudo -S -p '' "$@"; else sudo -n "$@"; fi; }
        fail() { echo "\(ProvisionScript.failMarker) $1" | tr '\\n' ' '; echo; rm -f "$0"; exit 1; }
        s true 2>/dev/null || fail \(failSudo)
        \(prelude)
        [ -n "$CUR" ] && [ "$(w 802-11-wireless.ssid "$CUR")" = "$SSID" ] && fail \(failAlreadyOn)
        # Find a saved profile for this SSID and the highest priority among client profiles.
        UUID=""; TOP=0
        while read -r u n; do
          [ -n "$u" ] || continue
          [ "$(w 802-11-wireless.mode "$u")" = "ap" ] && continue
          p=$(w connection.autoconnect-priority "$u")
          case "$p" in ''|*[!0-9-]*) p=0 ;; esac
          [ "$p" -gt "$TOP" ] && TOP=$p
          [ -z "$UUID" ] && [ "$(w 802-11-wireless.ssid "$u")" = "$SSID" ] && UUID=$u
        done <<EOF
        $(wifi_profiles)
        EOF
        PRIO=$((TOP + 10))
        SEC=()
        [ -n "$PASS" ] && SEC=(wifi-sec.key-mgmt "$KM" wifi-sec.psk "$PASS")
        NEW=0; OLDPRIO=""; OLDAC=""; OLDKM=""; OLDPSK=""
        if [ -n "$UUID" ]; then
          OLDPRIO=$(w connection.autoconnect-priority "$UUID")
          OLDAC=$(w connection.autoconnect "$UUID")
          if [ -n "$PASS" ]; then
            OLDKM=$(s nmcli -s -e no -g 802-11-wireless-security.key-mgmt connection show uuid "$UUID" 2>/dev/null)
            OLDPSK=$(s nmcli -s -e no -g 802-11-wireless-security.psk connection show uuid "$UUID" 2>/dev/null)
          fi
          ERR=$(s nmcli connection modify uuid "$UUID" connection.autoconnect yes connection.autoconnect-priority "$PRIO" "${SEC[@]}" 2>&1) || fail "$ERR"
        else
          NEW=1
          OUT=$(s nmcli connection add type wifi ifname "$DEV" con-name "ugv-$SSID" ssid "$SSID" connection.autoconnect yes connection.autoconnect-priority "$PRIO" "${SEC[@]}" 2>&1) || fail "$OUT"
          UUID=$(printf '%s' "$OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
          [ -n "$UUID" ] || fail "$OUT"
        fi
        e \(switchMarker) "$(hostname)\t$UUID\t$NEW\t$PRIO"
        rm -f "$T/ugv_wifi_result"
        { declare -p SSID UUID CUR DEV NEW OLDPRIO OLDAC OLDKM OLDPSK T; cat <<'EOS'
        sleep \(delay)
        echo "$(date +%T) switching to $SSID ($UUID), fallback ${CUR:-AccessPopup}"
        res() { umask 022; printf '%s\\t%s\\t%s\\n' "$1" "$SSID" "$2" > "$T/ugv_wifi_result"; }
        if OUT=$(nmcli --wait 40 connection up uuid "$UUID" 2>&1); then
          res ok "$(nmcli -g IP4.ADDRESS device show "$DEV" 2>/dev/null | head -1)"
        else
          echo "$(date +%T) failed: $OUT"
          if [ "$NEW" = 1 ]; then
            nmcli connection delete uuid "$UUID"
          else
            R=(connection.autoconnect-priority "${OLDPRIO:-0}" connection.autoconnect "${OLDAC:-yes}")
            [ -n "$OLDPSK" ] && R+=(802-11-wireless-security.key-mgmt "$OLDKM" 802-11-wireless-security.psk "$OLDPSK")
            nmcli connection modify uuid "$UUID" "${R[@]}"
          fi
          res fail "$(printf '%s' "$OUT" | tr '\\n\\t' '  ')"
          if [ -z "$CUR" ] || ! nmcli --wait 40 connection up uuid "$CUR"; then
            command -v accesspopup >/dev/null && accesspopup
          fi
        fi
        echo "$(date +%T) done"
        rm -f "$0"
        EOS
        } > "$T/.ugv_switch.sh"
        s setsid nohup bash "$T/.ugv_switch.sh" >> "$T/ugv_wifi_switch.log" 2>&1 < /dev/null &
        rm -f "$0"
        echo "\(ProvisionScript.okMarker)"
        """
    }

    /// Prints the outcome of the last switch (empty if it hasn't finished).
    public static func readResult(tmp: String = "/tmp") -> String {
        """
        \(prelude)
        e \(resultMarker) "$(cat \(Shell.quote(tmp))/ugv_wifi_result 2>/dev/null)"
        e \(curMarker) "$(hostname)\t$(w 802-11-wireless.ssid "$CUR")\t$(w 802-11-wireless.mode "$CUR")\t$(nmcli -g IP4.ADDRESS device show "$DEV" 2>/dev/null | head -1)"
        rm -f "$0"
        echo "\(ProvisionScript.okMarker)"
        """
    }

    // MARK: - Parsing

    /// Decoded payloads of every `marker` line, split on tabs.
    static func records(_ marker: String, in output: String) -> [[String]] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> [String]? in
            guard let r = line.range(of: marker + " ") else { return nil }
            let token = line[r.upperBound...].prefix { !$0.isWhitespace }
            guard let data = Data(base64Encoded: String(token)) else { return nil }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
    }

    public static func parseSurvey(_ output: String) -> RoverWiFiSurvey {
        var s = RoverWiFiSurvey()
        if let c = records(curMarker, in: output).first {
            s.hostname = c[safe: 0].nonEmpty
            s.currentSSID = c[safe: 1].nonEmpty
            s.currentIsAccessPoint = c[safe: 2] == "ap"
            s.ipv4 = c[safe: 3].nonEmpty?.split(separator: "/").first.map(String.init)
        }
        // nmcli -t -e no: IN-USE:SIGNAL:SECURITY:SSID — the SSID (last) may itself contain colons.
        var best: [String: RoverWiFiNetwork] = [:]
        for r in records(netMarker, in: output) {
            let f = r.joined(separator: "\t").split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, !f[3].isEmpty else { continue }
            let n = RoverWiFiNetwork(ssid: f[3], signal: Int(f[1]) ?? 0, security: f[2] == "--" ? "" : f[2],
                                     inUse: f[0].trimmingCharacters(in: .whitespaces) == "*")
            if let old = best[n.ssid], old.signal >= n.signal && !n.inUse { continue }
            best[n.ssid] = n
        }
        s.nearby = best.values.sorted { ($0.inUse ? 1 : 0, $0.signal) > ($1.inUse ? 1 : 0, $1.signal) }
        s.saved = records(savedMarker, in: output).compactMap { r in
            guard let name = r[safe: 0].nonEmpty else { return nil }
            return RoverSavedNetwork(name: name, ssid: r[safe: 2] ?? "", priority: Int(r[safe: 3] ?? "") ?? 0,
                                     isAccessPoint: r[safe: 1] == "ap")
        }
        return s
    }

    /// (hostname, profile UUID, created a new profile) from the switch script.
    public static func parseSwitch(_ output: String) -> (hostname: String?, uuid: String, isNew: Bool)? {
        guard let r = records(switchMarker, in: output).first, let uuid = r[safe: 1].nonEmpty else { return nil }
        return (r[safe: 0].nonEmpty, uuid, r[safe: 2] == "1")
    }

    public static func parseResult(_ output: String) -> RoverWiFiResult? {
        guard let r = records(resultMarker, in: output).first, r.count >= 3,
              r[0] == "ok" || r[0] == "fail" else { return nil }
        return RoverWiFiResult(ok: r[0] == "ok", ssid: r[1],
                               detail: r[2].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
