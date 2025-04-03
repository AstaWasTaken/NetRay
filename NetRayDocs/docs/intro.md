---
sidebar_position: 1
title: Introduction
---

# Introduction to NetRay

**NetRay** is a modern, high-performance networking library for Roblox, designed to enhance developer experience and runtime efficiency. It builds upon Roblox's core networking features, offering optimizations, increased reliability, and a more structured approach to client-server communication.

## Key Features

-   ⚡ **Optimized Performance:** Automatic event batching, efficient binary serialization, and intelligent compression (LZW) minimize network overhead.
-   🔒 **Reliability:** Integrated Circuit Breakers prevent cascading failures during network issues, improving service stability.
-   🛡️ **Type Safety:** Optionally define data structures using a string-based schema to validate payloads automatically, reducing runtime errors.
-   ⚙️ **Flexibility & Extensibility:** A powerful Middleware system allows you to intercept, modify, or block network traffic for logging, validation, rate limiting, etc.
-   🚀 **Developer Experience:** A clean API using Promises for asynchronous request/response patterns and prioritized event queues simplifies complex networking logic.
-   📊 **Monitoring:** Built-in debugging signals provide insight into network traffic patterns, errors, and internal operations.

## When to Use NetRay?

Consider NetRay if you need:

*   Improved network performance, especially when sending frequent updates.
*   More robust error handling and fault tolerance (Circuit Breakers).
*   Data validation to ensure communication integrity.
*   A structured way to manage different types of network communication (events vs. requests).
*   Centralized control over network flow via Middleware.
*   Prioritized handling of client-side events.

## Getting Started

Ready to integrate NetRay? Jump to the **[Getting Started](./getting-started.md)** guide.