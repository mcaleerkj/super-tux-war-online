# Super Tux War
A fan-inspired arena platformer built with Godot 4, following Super Mario War conventions. Battle in fast-paced multiplayer arenas where the goal is simple: stomp your opponents by landing on their heads while avoiding getting stomped yourself. Navigate 32×32 tile-based levels with precise platforming controls, one-way platforms, and hazards.

Website: https://supertuxwar.com

<div align="center">

### 🎮 [**PLAY NOW IN YOUR BROWSER**](https://mcaleerkj.github.io/super-tux-war-online/) 🎮

</div>


---

<img width="1281" height="707" alt="2025-12-08_23-31-48" src="https://github.com/user-attachments/assets/86f070ce-5f52-4d7f-9633-b49e07961f64" />


*Current tile map test level with 7 cpu players*

- *Tux*: Player character
- *FreeBSD Beastie*: NPC

*Controls*
- Move: A/D or Left/Right
- Jump: Space or W
- Turbo: Shift
- Drop through platforms: S+Space (Down+Jump)
- Xbox/gamepad: Left Stick or D-pad to move, A to jump/select, X/B/RT to
  sprint, B to go back, and Menu/Start to pause

## Online friend matches

The browser build supports private two-player Frag Limit matches. One player
chooses **Online Game → Create Private Room**, shares the eight-character code,
and the other joins from the same browser link. The host selects the arena and
frag goal; both players choose a character and ready up.

Online play uses host-authoritative WebRTC with prediction for the joining
player. Keep the game window active while playing—browsers suspend background
tabs. Public matchmaking, accounts, CPUs, and non-Frag online modes are not in
the first version.

Deployment requires the small Cloudflare signaling/TURN service in
[`services/signaling`](services/signaling/README.md). See the
[online multiplayer guide](docs/developers/online-multiplayer.md) for setup and
testing.

---

## Documentation

📖 **[Complete Documentation](docs/README.md)** - Comprehensive guides for developers and level designers

**Quick Links**:
- **[Level Design Guide](docs/level-design/README.md)** - Create levels for Super Tux War
- **[Character System](docs/character-system/README.md)** - Component-based character architecture
- **[Contributing Guide](docs/CONTRIBUTING.md)** - How to contribute (includes needed assets list)
- **[Roadmap](docs/ROADMAP.md)** - Feature roadmap and development priorities
- **[Online Multiplayer](docs/developers/online-multiplayer.md)** - Architecture, deployment, and testing

---

## Contributing

We welcome contributions! See **[CONTRIBUTING.md](docs/CONTRIBUTING.md)** for detailed guidelines.

**Quick summary**:
- Fork → feature branch → PR
- Follow GDScript style guidelines
- Test thoroughly (with 1 player + 7 NPCs)
- Keep PRs focused and small
- See [CONTRIBUTING.md](docs/CONTRIBUTING.md) for what we need (assets, features, etc.)

By contributing, you agree to license your work under the MIT License.

## Community

- Discord: [Super Tux War](https://discord.gg/J8eEp6dsHx)

## Acknowledgements
- Inspired by community-made arena platformers like Super Mario War.
- Thanks to all open-source contributors and tool authors (Godot, LibreSprite, etc.).

## Legal
- We do not use actual third‑party logos. Characters and items are original, non‑confusing stylizations to avoid trademark infringement and usage restrictions.
- No Nintendo IP.
- Attributions are included in-source and/or in-game where required (e.g., if any artwork derives from assets that require attribution). If you contribute assets needing attribution, include the attribution text in your PR.
- By contributing, you agree your code and assets are licensed under MIT for this project.
