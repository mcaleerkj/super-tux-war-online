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

`network_config.json` points local web exports to `http://127.0.0.1:8787`.
Godot's online button is intentionally enabled only in a web export; native
editor builds would require the separate WebRTC native extension.

## Cloudflare deployment

1. Create a Cloudflare Worker account and a Realtime TURN key.
2. Keep the localhost `ALLOWED_ORIGINS` value for local development.
3. Add the runtime secrets:

   ```sh
   cd services/signaling
   npx wrangler secret put TURN_KEY_ID
   npx wrangler secret put TURN_API_TOKEN
   npm run deploy -- --var "ALLOWED_ORIGINS:https://mcaleerkj.github.io"
   ```

   The value after `secret put` is the binding name. Paste the corresponding
   credential only when Wrangler prompts for its secret value.

4. Add repository secrets `CLOUDFLARE_ACCOUNT_ID` and
   `CLOUDFLARE_API_TOKEN` for Worker deployment.
5. Add repository variable `GAME_ORIGIN` containing the exact GitHub Pages
   origin, `https://mcaleerkj.github.io`; the deployment passes it to the
   Worker as its production CORS allowlist.
6. Add repository variable `SIGNALING_BASE_URL` containing the deployed Worker
   origin, `https://super-tux-war-signaling.mcaleerkj.workers.dev`.

Release tags deploy the Worker, inject that public URL into
`network_config.json`, export with Godot 4.7.1, and publish GitHub Pages. TURN
keys remain only in Cloudflare; browsers receive six-hour credentials.

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
