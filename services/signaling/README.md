# Super Tux War signaling service

This Cloudflare Worker creates private two-player rooms, relays WebRTC SDP/ICE
through a hibernating Durable Object, and returns short-lived Cloudflare TURN
credentials. Gameplay packets never pass through the Worker.

## Local development

```sh
npm install
npm test
npm run typecheck
npm run dev
```

`network_config.json` already points debug web exports at
`http://127.0.0.1:8787`.

## Production setup

1. Set the GitHub repository variable `GAME_ORIGIN` to the exact GitHub Pages
   origin. The release workflow supplies it as the Worker's `ALLOWED_ORIGINS`
   value while keeping localhost available in the checked-in development config.
2. Create a Cloudflare Realtime TURN key.
3. Store its credentials in the Worker; never put them in the Godot project:

```sh
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_API_TOKEN
npm run deploy
```

4. Set the GitHub repository secrets `CLOUDFLARE_ACCOUNT_ID` and
   `CLOUDFLARE_API_TOKEN`, then set the repository variable
   `SIGNALING_BASE_URL` to the deployed Worker URL. The Pages workflow injects
   it into the exported game.
