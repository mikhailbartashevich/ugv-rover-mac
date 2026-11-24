import Foundation

/// The bash script run on the rover to move it onto a Wi‑Fi network.
///
/// It adds a NetworkManager profile `ugv-home`, prints markers the app waits for,
/// then — detached, so it survives the terminal closing and the hotspot dropping —
/// lets AccessPopup switch wlan0 from hotspot to that network.
public enum ProvisionScript {
    public static let okMarker = "__UGV_OK__"
    public static let failMarker = "__UGV_FAIL__"
    public static let infoMarker = "__UGV_INFO__"

    public static func make(ssid: String, password: String, sudoPassword: String) -> String {
        let sec = password.isEmpty ? "" : "wifi-sec.key-mgmt wpa-psk wifi-sec.psk \"$PASS\""
        return """
        SSID=\(Shell.quote(ssid))
        PASS=\(Shell.quote(password))
        PW=\(Shell.quote(sudoPassword))
        s() { if [ -n "$PW" ]; then printf '%s\\n' "$PW" | sudo -S -p '' "$@"; else sudo -n "$@"; fi; }
        if ! s true 2>/dev/null; then echo "\(failMarker) sudo"; rm -f "$0"; exit 1; fi
        s nmcli connection delete ugv-home >/dev/null 2>&1
        if ! ERR=$(s nmcli connection add type wifi ifname wlan0 con-name ugv-home ssid "$SSID" \(sec) connection.autoconnect yes connection.autoconnect-priority 50 2>&1); then
          echo "\(failMarker) $ERR" | tr '\\n' ' '; echo; rm -f "$0"; exit 1
        fi
        echo "\(infoMarker) $(hostname) $(cat /sys/class/net/wlan0/address 2>/dev/null)"
        cat > /tmp/.ugv_switch.sh <<EOS
        sleep 3
        if command -v accesspopup >/dev/null; then accesspopup; else nmcli connection up ugv-home; fi
        rm -f /tmp/.ugv_switch.sh
        EOS
        s setsid nohup bash /tmp/.ugv_switch.sh >/tmp/ugv_switch.log 2>&1 < /dev/null &
        rm -f "$0"
        echo "\(okMarker)"
        """
    }

    /// Terminal lines that write the script to the rover and run it. The script is
    /// base64-encoded (so markers don't show up in the echo) and sent in short lines,
    /// because terminals can truncate very long input.
    static func terminalLines(for script: String) -> [String] {
        let b64 = Data(script.utf8).base64EncodedString()
        var lines = ["umask 077; rm -f /tmp/.ugv_b64"]
        var rest = Substring(b64)
        while !rest.isEmpty {
            lines.append("printf %s '\(rest.prefix(400))' >> /tmp/.ugv_b64")
            rest = rest.dropFirst(400)
        }
        lines.append("base64 -d < /tmp/.ugv_b64 > /tmp/.ugv_wifi.sh; rm -f /tmp/.ugv_b64; bash /tmp/.ugv_wifi.sh")
        return lines
    }

    /// Text on the line after `marker` in terminal output.
    static func value(after marker: String, in output: String) -> String? {
        guard let r = output.range(of: marker) else { return nil }
        return output[r.upperBound...].split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
