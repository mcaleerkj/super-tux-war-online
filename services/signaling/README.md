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

`npm run dev` passes the localhost `ALLOWED_ORIGINS` to Wrangler, and a web
export served from `127.0.0.1` or `localhost` automatically targets this local
Worker instead of the deployed one. Neither side needs editing to develop.

## Production setup

1. Create a Cloudflare Realtime TURN key.
2. Store its credentials in the Worker; never put them in the Godot project:

```sh
npx wrangler secret put TURN_KEY_ID
npx wrangler secret put TURN_API_TOKEN
npm run deploy
```

3. Set the GitHub repository secrets `CLOUDFLARE_ACCOUNT_ID` and
   `CLOUDFLARE_API_TOKEN` so the release workflow can deploy.

Deployment configuration is committed rather than supplied by repository
variables or CLI flags, so a manual `npm run deploy` matches what CI produces.
Forks change two values: `vars.ALLOWED_ORIGINS` in `wrangler.jsonc` (the CORS
allowlist, exercised by `npm test`) and `signaling_base_url` in the project's
`network_config.json` (checked by the Godot unit tests).
