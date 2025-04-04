# NetRay

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) 
[![DevForum Post](https://img.shields.io/badge/DevForum-Post-blue)](https://devforum.roblox.com/t/netray-high-performance-roblox-networking-library/3592849)
[![Documentation](https://img.shields.io/badge/Documentation-purple)](https://astawastaken.github.io/NetRay/)


> High-Performance Roblox Networking Library

NetRay aims to simplify and streamline client-server communication in Roblox using RemoteEvents and RemoteFunctions, providing a structured, efficient, and easier-to-manage approach compared to manual remote instance handling.

## 🤔 Why NetRay?

Managing dozens of individual `RemoteEvent` and `RemoteFunction` instances can quickly become messy and error-prone. NetRay offers:

⚡
Optimized Performance
Automatic event batching, efficient binary serialization, and intelligent compression reduce network load and improve responsiveness.

🔒
Enhanced Reliability
Built-in Circuit Breakers prevent cascading failures, while robust error handling and timeouts make your networking more resilient.

🛡️
Type Safety & Validation
Define data structures for your events and requests. NetRay automatically validates payloads, catching errors early in development.

⚙️
Flexible Middleware
Intercept, modify, or block network traffic using a powerful middleware system. Implement logging, rate limiting, or custom validation with ease.

🚀
Modern Developer Experience
Clean API using Promises for asynchronous requests, clear event handling patterns, and priority queues simplify complex networking code.

📊
Built-in Monitoring
Debug signals provide visibility into internal events, errors, and potentially network traffic, aiding optimization and troubleshooting.

## ✨ Features

*   Define client->server and server->client communication easily.
*   Abstraction over `RemoteEvent` and `RemoteFunction`.
*   Middleware support
*   Automatic Server and Client Rate Limiting
*   Dynamic Sender - Automatically selects the best method of sending your data
*   And Many More!


## 🚀 Getting Started

### Installation

1.  **Download:** Grab the latest `.rbxmx` model file from the [Releases page](https://github.com/AstaWasTaken/NetRay/releases).
2.  **Import:** Insert the downloaded model into Roblox Studio, placing it in ReplicatedStorage.

### Quick Start Example

```lua
--[[ Server Script (e.g., in ServerScriptService) ]]

-- Server: Register and handle an event
local myEvent = NetRay:RegisterEvent("SimpleGreeting", {
  typeDefinition = { message = "string" }
})

myEvent:OnEvent(function(player, data)
  print(player.Name, "sent:", data.message)

  -- Reply back to just that player
  myEvent:FireClient(player, { message = "Server received: ".. data.message })
end)

print("NetRay Server event handler ready.")
```

```lua
--[[ Local Script (e.g., in StarterPlayerScripts) ]]

-- Client: Get event reference and interact
local myEvent = NetRay:GetEvent("SimpleGreeting")

-- Listen for server's reply
myEvent:OnEvent(function(data)
  print("Server replied:", data.message)
end)

-- Fire event to server after a delay
task.delay(3, function()
  local playerName = game:GetService("Players").LocalPlayer.Name
  print("Client sending greeting...")
  myEvent:FireServer({ message = "Hello from ".. playerName })
end)
```

📚 Documentation
For detailed information, API reference, and advanced usage guides, please visit our documentation website:

[NetRay Documentation](https://astawastaken.github.io/NetRay/)

🤝 Contributing
Contributions are welcome! Please feel free to submit Pull Requests or open Issues for bugs, feature requests, or questions.


📜 License
NetRay is licensed under the MIT License. See the LICENSE file for details.
