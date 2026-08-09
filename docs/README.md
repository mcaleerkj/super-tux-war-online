# Super Tux War Documentation

Welcome to the Super Tux War documentation! This is a comprehensive guide for developers, level designers, and contributors.

## 📚 Documentation Sections

### [Level Design](level-design/README.md)
Complete guide to creating and designing levels for Super Tux War.

- **[Getting Started](level-design/getting-started.md)** - Create your first level
- **[Tile Layers & Block Types](level-design/tile-layers.md)** - Understanding the tile system
- **[Spawn Points](level-design/spawn-points.md)** - Character spawning system
- **[Level Thumbnails](level-design/level-thumbnails.md)** - Automatic thumbnail generation
- **[Navigation Graph](level-design/navigation-graph.md)** - AI pathfinding system

### [Contributing Guide](CONTRIBUTING.md)
How to contribute code, assets, documentation, and more. Includes list of needed assets.

### [Roadmap](ROADMAP.md)
Feature roadmap and development priorities (multiplayer, sound system, game modes, etc.).

### [Character System](character-system/README.md)
Component-based character architecture for players and NPCs.

- **[Character System Overview](character-system/README.md)** - Architecture and components
- **[Character Controller](character-system/character-controller.md)** - Main controller coordination
- **[Physics Component](character-system/physics-component.md)** - Movement, jumping, gravity
- **[Lifecycle Component](character-system/lifecycle-component.md)** - Death, respawn, spawn protection

### Core Systems

- **[Acceleration Physics](ACCELERATION_PHYSICS.md)** - SMW-style momentum-based movement system
- **[Debug Launch Config](debug-launch-config.md)** - Local-only scene + debug overrides
- **Event Bus** *(coming soon)* - Event system architecture
- **Game State** *(coming soon)* - State management
- **Input Management** *(coming soon)* - Input handling

## 🎮 Quick Links

- [Main README](../README.md) - Project overview and game design
- [Play in Browser](https://mcaleerkj.github.io/super-tux-war-online/)
- [Godot 4.7.1 Documentation](https://docs.godotengine.org/en/4.7/)

## 📖 About This Documentation

This documentation is maintained alongside the code in the `docs/` folder. When making code changes, please update the relevant documentation to keep everything in sync.

### Documentation Standards

- Use clear, concise language
- Include code examples where relevant
- Add screenshots/diagrams when helpful
- Keep file paths relative to project root
- Follow markdown best practices

## 🔧 Technical Overview

### Project Structure

```
super-tux-wars/
├── assets/          # Sprites, tiles, audio
├── scenes/          # Scene files (.tscn)
├── scripts/         # GDScript code
│   ├── characters/  # Player & NPC logic
│   ├── core/        # Core systems
│   ├── levels/      # Level management
│   ├── objects/     # Interactive objects
│   └── ui/          # User interface
├── addons/          # Editor plugins
└── docs/            # This documentation
```

### Core Constants

The game uses **32×32 pixel tiles** and **SMW-style acceleration physics** defined in `GameConstants`:

- **Tile Size**: 32px
- **Acceleration**: 30 px/s² (7.5 px/s² on ice)
- **Friction**: 12 px/s² ground, 3.6 px/s² ice/air
- **Gravity**: 1440 px/s²
- **Jump Velocity**: -540 px/s
- **Max Walk Speed**: 240 px/s
- **Max Run Speed**: 330 px/s (turbo)

See [game_constants.gd](../scripts/core/game_constants.gd) for complete values and [Acceleration Physics](ACCELERATION_PHYSICS.md) for detailed behavior.

## 🤝 Contributing to Documentation

Found a mistake or want to improve the docs? Contributions are welcome!

1. Edit markdown files in the `docs/` folder
2. Test that links work correctly
3. Submit a PR with your changes

---

**Version**: Godot 4.7.1  
**Last Updated**: 2025-11-09
