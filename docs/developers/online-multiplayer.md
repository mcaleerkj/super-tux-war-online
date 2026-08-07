# Online multiplayer

Super Tux War's first online release is a browser-only, private two-player Frag
Limit match. The host is authoritative for physics, stomps, deaths, respawns,
scores, and match completion. The guest sends sequenced inputs, predicts its
own static-world movement, reconciles to host snapshots, and interpolates the
host avatar.

## Data path

1. The game creates or joins a room through the Cloudflare Worker.
2. A hibernating Durable Object relays SDP and ICE messages between two
   authenticated, single-use WebSocket tickets.
3. The browsers establish a WebRTC data-channel connection, direct when
   possible and through Cloudflare TURN when required.
4. Gameplay travels only over WebRTC. Reliable channel 0 carries lobby and
   lifecycle events; unreliable-ordered channel 1 carries 60 Hz guest input
   and 20 Hz host snapshots.

The stable network node is the `NetworkSession` autoload. Wire payloads use
peer IDs 1 (host) and 2 (guest), allowlisted level/character IDs, and protocol
version 1. Scene objects and arbitrary resource paths are never accepted over
the network.

## Local service

Install Node.js 24, then run:

```sh
cd services/signaling
npm install
npm test
npm run typecheck
npm run dev
```

`network_config.json` carries the deployed Worker URL, so any export is
playable as built. A build served from a host listed in its `local_hosts` array
switches to `local_signaling_base_url` (`http://127.0.0.1:8787`) instead, which
is what makes `npm run dev` work without editing or rewriting the file. The
`dev` script passes the matching localhost CORS allowlist to Wrangler.

Godot's online button is intentionally enabled only in a web export; native
editor builds would require the separate WebRTC native extension.

## Recovering a dropped signaling socket

Signaling tickets are single-use and burned when the WebSocket connects. If the
socket drops before WebRTC finishes negotiating, the client trades its role
secret for a fresh ticket via `POST /v1/rooms/{code}/signal-ticket`, reopens the
socket, and replays the SDP and ICE it already produced; duplicate descriptions
are ignored on receipt. The Durable Object evicts the stale socket for that role
rather than answering 409, and suppresses the `peer_left` notice for an evicted
socket so the waiting player never sees a spurious disconnect. Recovery is
capped at three attempts per session.

This covers the signaling phase only. Once gameplay is running on the data
channel, v1 still ends the match after a ten-second timeout rather than
attempting host migration or reconnection.

## Cloudflare deployment

1. Create a Cloudflare Worker account and a Realtime TURN key.
2. Add the runtime secrets:

   ```sh
   cd services/signaling
   npx wrangler secret put TURN_KEY_ID
   npx wrangler secret put TURN_API_TOKEN
   npm run deploy
   ```

   The value after `secret put` is the binding name. Paste the corresponding
   credential only when Wrangler prompts for its secret value.

3. Add repository secrets `CLOUDFLARE_ACCOUNT_ID` and `CLOUDFLARE_API_TOKEN`
   for Worker deployment.

Forking this project means changing two committed values, both of which CI
checks or exercises:

| Setting | File | Value |
| --- | --- | --- |
| CORS allowlist | `services/signaling/wrangler.jsonc` (`vars.ALLOWED_ORIGINS`) | your Pages origin |
| Signaling URL | `network_config.json` (`signaling_base_url`) | your deployed Worker origin |

Both deliberately live in version control rather than in repository variables
or CLI flags: a manual `npm run deploy` or a local `--export-release` then
produces exactly what the release workflow does, instead of silently shipping a
localhost-only build or locking the live game out of its own signaling service.

Release tags deploy the Worker, export with Godot 4.7.1, and publish GitHub
Pages. TURN keys remain only in Cloudflare; browsers receive six-hour
credentials.

## Verification

Run the local automated checks:

```powershell
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . --script res://tests/run_tests.gd
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://tests/offline_modes_smoke.tscn
& "C:\path\to\Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://tests/online_match_smoke.tscn
```

Before release, use two desktop browser windows on different networks and test
room creation, join, ready/start, movement, wrapping, stomps, respawns, the
frag winner, rematch, return to lobby, and disconnects. Use browser WebRTC
diagnostics to confirm both a direct candidate and a TURN `relay` candidate.

Keep both game windows visible. Browsers can suspend background tabs, and v1
intentionally ends the match after a ten-second connection timeout rather than
attempting host migration or reconnection.
