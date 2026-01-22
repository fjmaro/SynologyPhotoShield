# SynologyPhotoShield
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Synology: DSM 7.3+](https://img.shields.io/badge/Synology-DSM%207.3%2B-blue.svg) ![Status: Stable](https://img.shields.io/badge/Status-Stable-green.svg)

Advanced integration for Synology Photos (DSM 7.2/7.3+). Automatically mounts user folders using 'mount --bind', triggers incremental indexing (basic mode) without system overhead, and applies a Read-Only (RO) shield to protect original data. Solves API Error 103.


## The Safe Sharing Challenge
Synology Photos is a powerful gallery, but it lacks a true **"Read-Only Viewer"** role for shared libraries or personal backups. If you give someone access to your timeline, you risk:
* **Accidental Deletions:** One wrong swipe can delete a photo, and you must recover it from snapshots or backups.
* **Unwanted Edits:** Changes to metadata or albums can mess up your organization.
* **The Dilemma:** You want your family or friends to enjoy the **Map View**, the **Timeline**, the **Smooth Zooming**, the **custom albums** (and more) features, but without the power to modify the source files.

The closest native workaround is sharing "Albums", but these **lack all the advanced features** mentioned above. Synology does not provide a native way to grant these "convenience features" while keeping the underlying files 100% safe.
**SynologyPhotoShield solves this** by decoupling the App's database from the file system's write permissions.


## The Solution
The script automates the entire lifecycle of the photo integration. It starts by cleaning up any existing mounts to ensure a fresh state, then identifies and creates the necessary empty destination structures within the Shared Space to map your source gallery. Once the folders are mounted in a temporary read-write state, it forces the Synology Photo Manager to detect changes and perform an incremental indexing. Finally, the script monitors system daemons to ensure all background tasks (like thumbnail generation) are complete before automatically switching all mounts to a Read-Only state, effectively armoring your data.


## Technical Requirements
* **OS:** Synology DSM 7.3+
* **App:** Synology Photos
* **Privileges:** Administrator user


## Installation & Usage
1. **Prepare Synology Photos:**
* Enable **Shared Space** in the App settings.
* Ensure the system folder `/photo` has been automatically created.
* Grant "Full Access" to the target users in the Shared Space permissions (the script's Read-Only armor will prevent any actual deletions, while the app allows full feature usage).

2. **Configure the Script:**
* Open the script and set your **Gallery Parent Folder** (the source directory containing your gallery photos/videos and subfolders).

3. **Deploy the Task:**
* Upload the script to your NAS.
* Go to **Control Panel** > **Task Scheduler**.
* Create a **User-defined script** task as **root**.
* Set it to run the script on boot or on a custom schedule.


## Project Metadata
* **Author:** Francisco Mata
* **GitHub:** [SynologyPhotoShield](https://www.google.com/search?q=https://github.com/tu-usuario/SynologyPhotoShield)
* **Version:** 1.0
* **Status:** Tested on DSM 7.3.2


## License & Disclaimer
This project is licensed under the **MIT License**. 

**Copyright (c) 2026 Francisco Mata Aroco**

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

*This project is provided "as is". Use it at your own risk. The author is not responsible for any data loss

---
