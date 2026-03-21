# ![App Icon](https://online.kevintobler.ch/projectimages/AppleContainerGUI.png) AppleContainerGUI

**AppleContainerGUI** is a native macOS SwiftUI front-end for the `container` CLI (Apple Container). It provides an organized, visual way to manage containers, images, volumes, networks, snapshots and logs.

Version **1.0** – developed by **Kevin Tobler** 🌐 [www.kevintobler.ch](https://www.kevintobler.ch)

It wraps common `container` workflows in a single window: start/stop the container system, inspect resources, run images, adjust resources, and review command logs without jumping between Terminal sessions.

---

## 🔄 Changelog

### 🆕 Version 1.x
- **1.0**
  - 🧭 Initial release of **AppleContainerGUI**
  - 🖥️ SwiftUI-based macOS interface
  - 🧰 Integrated Homebrew install flow for Apple Container CLI

---

## 🚀 Features

- ▶️ Start/stop Apple Container system services
- 📦 Manage containers (refresh, start/stop, delete, inspect)
- 🧠 Edit container resources (CPU, memory)
- 🧰 Update container images and open related folders
- 🧱 Manage images (refresh, delete, run, inspect)
- 📂 Manage volumes (create, delete, open in Finder, fix permissions)
- 🌐 Manage networks (refresh, delete, inspect)
- 🔎 Search container registries (Docker Hub, GitHub, Quay, GitLab, custom)
- 🧩 Docker-like command compatibility so Docker users need no workflow changes
- 🧪 Run images with ports, volumes, environment and command overrides
- 📸 Snapshot management (list, delete, bulk delete)
- 🧾 Built-in command log with output and errors

---

## 📸 Screenshots

![Screenshot](https://online.kevintobler.ch/projectimages/AppleContainerGUIV1-container.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/AppleContainerGUIV1-images.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/AppleContainerGUIV1-search.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/AppleContainerGUIV1-command.png)  

---

## ⚙️ How It Works

AppleContainerGUI uses the Apple Container CLI (`container`) under the hood and parses its JSON output to populate tables and inspectors. It runs common commands such as:

- `container system start` / `container system stop`
- `container ps`, `container images`, `container volume ls`, `container network ls`
- `container inspect` and related detail commands

If the CLI is missing, the app offers to install it via Homebrew and shows the live installation progress.

---

## 🔧 Installation

[![Download AppleContainerGUI](https://img.shields.io/badge/Download-AppleContainerGUI-blue)](https://github.com/KeepCoolCH/AppleContainerGUI/releases/tag/V.1.0)

1. Run **AppleContainerGUI.app**
2. Install **Homebrew** if needed (the app shows the correct prompt)
3. Install the Apple Container CLI: `brew install container` (automatic install via the app)
4. Install the kernel (automatic install via the app)

> 🧱 Requires macOS 26 Tahoe or newer

---

## 🧑‍💻 Developer

**Kevin Tobler**  
🌐 [www.kevintobler.ch](https://www.kevintobler.ch)

---

## 📜 License

This project is licensed under the **MIT License** – feel free to use, modify, and distribute.
