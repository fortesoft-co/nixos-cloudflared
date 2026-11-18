# The setup and DNS units against a stub of the Cloudflare API: the tunnel is
# created once and reused, its token is stored root-only, a CNAME lands in
# the right zone for each ingress hostname (including a multi-label public
# suffix), and the API token never shows up on a command line.
{ pkgs, self }:
let
  stub = pkgs.writeText "cloudflare-stub.py" ''
    import json, re
    from http.server import BaseHTTPRequestHandler, HTTPServer

    state = {"tunnels": [], "records": [], "auth": set()}
    zones = {"example.com": "zone-com", "example.co.uk": "zone-couk"}

    class H(BaseHTTPRequestHandler):
        def reply(self, result, code=200):
            body = json.dumps({"success": code < 400, "result": result}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)

        def handle_any(self):
            n = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(n)) if n else None
            path, _, query = self.path.partition("?")
            q = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
            method = self.command
            if path == "/state":
                return self.reply({"tunnels": state["tunnels"], "records": state["records"],
                                   "auth": sorted(state["auth"])})
            state["auth"].add(self.headers.get("Authorization", ""))
            if self.headers.get("Authorization") != "Bearer test-api-token-xyz":
                return self.reply(None, 403)
            if re.fullmatch(r"/accounts/acct-1/cfd_tunnel", path):
                if method == "GET":
                    return self.reply([{"id": t["id"], "name": t["name"], "deleted_at": None}
                                       for t in state["tunnels"]])
                t = {"id": "tunnel-%d" % (len(state["tunnels"]) + 1), "name": data["name"]}
                state["tunnels"].append(t)
                return self.reply(t)
            if m := re.fullmatch(r"/accounts/acct-1/cfd_tunnel/([^/]+)", path):
                return self.reply({"id": m.group(1), "account_tag": "acct-1"})
            if re.fullmatch(r"/accounts/acct-1/cfd_tunnel/[^/]+/token", path):
                return self.reply("tunnel-token-secret")
            if path == "/zones":
                z = zones.get(q.get("name"))
                return self.reply([{"id": z}] if z else [])
            if mm := re.fullmatch(r"/zones/([^/]+)/dns_records", path):
                if self.command == "GET":
                    return self.reply([r for r in state["records"]
                                       if r["zone"] == mm.group(1) and r["name"] == q.get("name")])
                r = dict(data, zone=mm.group(1), id="rec-%d" % (len(state["records"]) + 1))
                state["records"].append(r)
                return self.reply(r)
            if mm := re.fullmatch(r"/zones/([^/]+)/dns_records/([^/]+)", path):
                for r in state["records"]:
                    if r["id"] == mm.group(2):
                        r.update(data)
                        return self.reply(r)
            return self.reply(None, 404)

        do_GET = do_POST = do_PUT = handle_any

    HTTPServer(("127.0.0.1", 8787), H).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "cloudflared-tunnel";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      networking.hostName = "gateway";
      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];

      systemd.services.cloudflare-stub = {
        wantedBy = [ "multi-user.target" ];
        before = [ "cloudflared-tunnel-setup-gateway.service" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -I ${stub}";
      };
      systemd.services.test-secrets = {
        wantedBy = [ "multi-user.target" ];
        before = [ "cloudflared-tunnel-setup-gateway.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /run/test-secrets
          umask 077
          echo acct-1 > /run/test-secrets/account-id
          echo test-api-token-xyz > /run/test-secrets/api-token
        '';
      };

      services.cloudflared-tunnel = {
        enable = true;
        accountIdFile = "/run/test-secrets/account-id";
        apiTokenFile = "/run/test-secrets/api-token";
        apiUrl = "http://127.0.0.1:8787";
      };
      services.cloudflared.tunnels.gateway.ingress = {
        "app.example.com" = "http://127.0.0.1:8080";
        "auth.example.co.uk" = {
          service = "https://127.0.0.1:443";
          originRequest.originServerName = "auth.example.co.uk";
        };
      };
    };

  testScript = ''
    import json

    def state():
        return json.loads(machine.succeed("curl -sf http://127.0.0.1:8787/state"))["result"]

    machine.wait_for_unit("cloudflare-stub.service")
    machine.wait_for_open_port(8787)
    machine.wait_for_unit("cloudflared-tunnel-setup-gateway.service")
    machine.wait_for_unit("cloudflared-update-dns-gateway.service")

    with subtest("the tunnel is created, and its token stored root-only"):
        s = state()
        assert [t["name"] for t in s["tunnels"]] == ["gateway"], s
        assert machine.succeed("stat -c '%a %U' /var/lib/cloudflared/.gateway.token").strip() == "600 root"
        assert machine.succeed("cat /var/lib/cloudflared/.gateway.token") == "tunnel-token-secret"

    with subtest("each ingress hostname gets a proxied CNAME in its own zone"):
        recs = {r["name"]: r for r in state()["records"]}
        assert set(recs) == {"app.example.com", "auth.example.co.uk"}, recs
        assert recs["app.example.com"]["zone"] == "zone-com", recs
        assert recs["auth.example.co.uk"]["zone"] == "zone-couk", recs
        assert all(r["content"] == "tunnel-1.cfargotunnel.com" and r["proxied"] for r in recs.values()), recs

    with subtest("rerunning reuses the tunnel and updates records in place"):
        machine.succeed("systemctl restart cloudflared-tunnel-setup-gateway.service cloudflared-update-dns-gateway.service")
        s = state()
        assert len(s["tunnels"]) == 1, s
        assert len(s["records"]) == 2, s

    with subtest("the API token is only used as a header, never on a command line"):
        # "" is the unauthenticated reachability probe.
        assert [a for a in state()["auth"] if a] == ["Bearer test-api-token-xyz"], state()["auth"]
        machine.fail("ps -eo args | grep -F test-api-token-xyz | grep -v grep")
        machine.fail("journalctl -b --no-pager | grep -F test-api-token-xyz")

    with subtest("an API failure leaves the setup unit failed but the tunnel up"):
        # A token without the needed permission: the API answers 403.
        machine.succeed("echo wrong-token > /run/test-secrets/api-token")
        machine.fail("systemctl restart cloudflared-tunnel-setup-gateway.service")
        assert machine.succeed("systemctl is-failed cloudflared-tunnel-setup-gateway.service || true").strip() == "failed"
        # The daemon starts from the stored token instead of failing on its
        # dependency, and the stored token is untouched.
        machine.succeed("systemctl restart cloudflared-tunnel-gateway.service")
        assert machine.succeed("cat /var/lib/cloudflared/.gateway.token") == "tunnel-token-secret"
        machine.succeed("echo test-api-token-xyz > /run/test-secrets/api-token")
        machine.succeed("systemctl restart cloudflared-tunnel-setup-gateway.service")

    with subtest("the daemon is started with the token as a credential"):
        unit = machine.succeed("systemctl cat cloudflared-tunnel-gateway.service")
        assert "LoadCredential=tunnel-token:/var/lib/cloudflared/.gateway.token" in unit, unit
  '';
}
