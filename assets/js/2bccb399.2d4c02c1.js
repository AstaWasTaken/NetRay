"use strict";(self.webpackChunknet_ray_docs=self.webpackChunknet_ray_docs||[]).push([[154],{2027:(e,n,r)=>{r.r(n),r.d(n,{assets:()=>l,contentTitle:()=>o,default:()=>g,frontMatter:()=>a,metadata:()=>i,toc:()=>c});const i=JSON.parse('{"id":"debugging","title":"Debugging & Monitoring","description":"NetRay provides built-in signals and utilities to help you understand its internal behavior, track down issues, and monitor performance.","source":"@site/docs/debugging.md","sourceDirName":".","slug":"/debugging","permalink":"/NetRay/docs/debugging","draft":false,"unlisted":false,"editUrl":"https://github.com/AstaWasTaken/NetRay/docs/debugging.md","tags":[],"version":"current","frontMatter":{"title":"Debugging & Monitoring"},"sidebar":"docsSidebar","previous":{"title":"Optimizations (Batching & Compression)","permalink":"/NetRay/docs/advanced-features/optimizations"},"next":{"title":"API Reference"}}');var t=r(4848),s=r(8453);const a={title:"Debugging & Monitoring"},o="Debugging & Monitoring",l={},c=[{value:"Enabling Debug Mode",id:"enabling-debug-mode",level:2},{value:"Debug Signals",id:"debug-signals",level:2},{value:"1. <code>NetRay.Debug.GlobalEvent</code>",id:"1-netraydebugglobalevent",level:3},{value:"2. <code>NetRay.Debug.Error</code>",id:"2-netraydebugerror",level:3},{value:"3. <code>NetRay.Debug.NetworkTraffic</code>",id:"3-netraydebugnetworktraffic",level:3},{value:"Monitoring Specific Components",id:"monitoring-specific-components",level:2},{value:"Circuit Breaker Signals",id:"circuit-breaker-signals",level:3},{value:"Middleware Metrics",id:"middleware-metrics",level:3},{value:"Example of Custom Event Handler with Debug Logging",id:"example-of-custom-event-handler-with-debug-logging",level:2},{value:"Tips for Debugging",id:"tips-for-debugging",level:2}];function d(e){const n={admonition:"admonition",code:"code",em:"em",h1:"h1",h2:"h2",h3:"h3",header:"header",li:"li",ol:"ol",p:"p",pre:"pre",strong:"strong",ul:"ul",...(0,s.R)(),...e.components};return(0,t.jsxs)(t.Fragment,{children:[(0,t.jsx)(n.header,{children:(0,t.jsx)(n.h1,{id:"debugging--monitoring",children:"Debugging & Monitoring"})}),"\n",(0,t.jsx)(n.p,{children:"NetRay provides built-in signals and utilities to help you understand its internal behavior, track down issues, and monitor performance."}),"\n",(0,t.jsx)(n.h2,{id:"enabling-debug-mode",children:"Enabling Debug Mode"}),"\n",(0,t.jsx)(n.p,{children:"To receive detailed logs and events from NetRay's debug signals, you first need to enable monitoring globally:"}),"\n",(0,t.jsx)(n.p,{children:"Do this early in your initialization script (client or server)"}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:"NetRay.Debug.EnableMonitoring({ enabled = true })\n"})}),"\n",(0,t.jsx)(n.p,{children:"Optional: You might add logging levels later if needed"}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:'NetRay.Debug.EnableMonitoring({ enabled = true, level = "verbose" })\n'})}),"\n",(0,t.jsx)(n.admonition,{type:"info",children:(0,t.jsxs)(n.p,{children:["Simply enabling monitoring makes NetRay ",(0,t.jsx)(n.em,{children:"fire"})," the signals. You still need to connect listeners to these signals to actually see or act upon the information."]})}),"\n",(0,t.jsx)(n.h2,{id:"debug-signals",children:"Debug Signals"}),"\n",(0,t.jsxs)(n.p,{children:["Access signals under the ",(0,t.jsx)(n.code,{children:"NetRay.Debug"})," table."]}),"\n",(0,t.jsxs)(n.h3,{id:"1-netraydebugglobalevent",children:["1. ",(0,t.jsx)(n.code,{children:"NetRay.Debug.GlobalEvent"})]}),"\n",(0,t.jsx)(n.p,{children:"This signal fires for a wide range of internal library events, providing a trace of operations."}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:'NetRay.Debug.GlobalEvent:Connect(function(context, signalName, ...)\r\n    -- context: "Server" or "Client"\r\n    -- signalName: Name of the internal signal that fired\r\n    -- ...: Arguments specific to that internal signal\r\n\r\n    local args = {...}\r\n    local argsString = ""\r\n    -- Basic serialization of args for printing\r\n    for i, v in ipairs(args) do\r\n        argsString = argsString .. tostring(v) .. (i < #args and ", " or "")\r\n    end\r\n\r\n    print(`[NetRay GLOBAL|${context}] ${signalName}(${argsString})`)\r\nend)\n'})}),"\n",(0,t.jsx)(n.p,{children:"Example Output:"}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:"[NetRay GLOBAL|Server] EventRegistered(PlayerAction)\r\n[NetRay GLOBAL|Client] RequestSent(GetInventory, {userId=123})\r\n[NetRay GLOBAL|Server] EventFired(PlayerAction, Player1, {...})\r\n[NetRay GLOBAL|Client] ThrottleExceeded(burst, 21, 20)\n"})}),"\n",(0,t.jsxs)(n.p,{children:["Internal signals proxied through ",(0,t.jsx)(n.code,{children:"GlobalEvent"})," include (but may not be limited to):"]}),"\n",(0,t.jsxs)(n.ul,{children:["\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.code,{children:"EventRegistered"}),", ",(0,t.jsx)(n.code,{children:"EventFired"})]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.code,{children:"RequestSent"}),", ",(0,t.jsx)(n.code,{children:"RequestReceived"})]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.code,{children:"RateLimitExceeded"}),", ",(0,t.jsx)(n.code,{children:"ThrottleExceeded"})," (Client/Server Manager specific signals)"]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.code,{children:"CircuitBroken"}),", ",(0,t.jsx)(n.code,{children:"CircuitReset"})," (Circuit Breaker signals)"]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.code,{children:"PlayerJoined"}),", ",(0,t.jsx)(n.code,{children:"PlayerLeft"})," (Server Manager signals)"]}),"\n"]}),"\n",(0,t.jsxs)(n.h3,{id:"2-netraydebugerror",children:["2. ",(0,t.jsx)(n.code,{children:"NetRay.Debug.Error"})]}),"\n",(0,t.jsx)(n.p,{children:"This signal fires when errors are caught within NetRay's core operations (e.g., middleware execution, message queue processing, internal pcalls)."}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:'NetRay.Debug.Error:Connect(function(context, source, ...)\r\n    -- context: "Server" or "Client"\r\n    -- source: Where the error originated (e.g., "Middleware", "ProcessMessage", "ServerManager", "ClientManager")\r\n    -- ...: Error message(s) or details\r\n\r\n    warn(`[NetRay ERROR|${context}] Source: ${tostring(source)} -`, ...)\r\nend)\n'})}),"\n",(0,t.jsx)(n.p,{children:"Example Output:"}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{children:"[NetRay ERROR|Client] Source: Middleware - [NetRay] Middleware error in 'BadValidator': attempt to index nil with 'userId'\r\n[NetRay ERROR|Server] Source: ProcessMessage - Error processing queued message: ...\n"})}),"\n",(0,t.jsxs)(n.h3,{id:"3-netraydebugnetworktraffic",children:["3. ",(0,t.jsx)(n.code,{children:"NetRay.Debug.NetworkTraffic"})]}),"\n",(0,t.jsx)(n.admonition,{title:"Placeholder",type:"caution",children:(0,t.jsxs)(n.p,{children:["The ",(0,t.jsx)(n.code,{children:"NetworkTraffic"})," signal is currently defined but acts as a ",(0,t.jsx)(n.strong,{children:"placeholder"}),". It is not automatically connected to measure actual network bytes sent/received. Implementing this would require deeper hooks into the ",(0,t.jsx)(n.code,{children:"RemoteEvent/Function:Fire..."})," calls or estimates based on serialized data sizes just before sending."]})}),"\n",(0,t.jsxs)(n.p,{children:["Example ",(0,t.jsx)(n.em,{children:"conceptual"})," connection if traffic stats were implemented:"]}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:'NetRay.Debug.NetworkTraffic:Connect(function(stats)\r\n    print("NetRay Traffic - Sent/s:", stats.bytesSentPerSec, "Recv/s:", stats.bytesReceivedPerSec)\r\nend)\n'})}),"\n",(0,t.jsx)(n.h2,{id:"monitoring-specific-components",children:"Monitoring Specific Components"}),"\n",(0,t.jsx)(n.p,{children:"You can often access internal components for more targeted monitoring."}),"\n",(0,t.jsx)(n.h3,{id:"circuit-breaker-signals",children:"Circuit Breaker Signals"}),"\n",(0,t.jsx)(n.p,{children:"Monitor state changes or failures for a specific endpoint."}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:'local cb = NetRay:GetCircuitBreaker("MyRiskyRequest")\r\nif cb then\r\n    cb.Signals.StateChanged:Connect(function(oldState, newState)\r\n        warn(("Circuit Breaker \'MyRiskyRequest\' state: %s -> %s"):format(oldState, newState))\r\n    end)\r\n    cb.Signals.FailureRecorded:Connect(function()\r\n        print("Failure recorded for MyRiskyRequest circuit breaker.")\r\n    end)\r\nend\n'})}),"\n",(0,t.jsx)(n.h3,{id:"middleware-metrics",children:"Middleware Metrics"}),"\n",(0,t.jsxs)(n.p,{children:["Access performance metrics for the middleware system. (Accessing ",(0,t.jsx)(n.code,{children:"NetRay.Server/Client.Middleware"})," depends on implementation details, might not be stable public API)."]}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:'-- Server side example (Assuming access path is stable)\r\ntask.delay(60, function()\r\n    while true do\r\n        if NetRay.Server and NetRay.Server.Middleware then\r\n            local metrics = NetRay.Server.Middleware:GetMetrics()\r\n            print("--- Middleware Metrics (Server) ---")\r\n            print(" Executions:", metrics.totalExecutions)\r\n            print(" Avg Time (ms):", metrics.avgExecutionTime and (metrics.avgExecutionTime * 1000) or "N/A")\r\n            print(" Blocked:", metrics.blocked, " Errors:", metrics.errors)\r\n            print(" Cache Hits:", metrics.cacheHits, " Misses:", metrics.cacheMisses)\r\n            print("----------------------------------")\r\n        end\r\n        task.wait(60) -- Log every minute\r\n    end)\r\nend\n'})}),"\n",(0,t.jsx)(n.h2,{id:"example-of-custom-event-handler-with-debug-logging",children:"Example of Custom Event Handler with Debug Logging"}),"\n",(0,t.jsx)(n.pre,{children:(0,t.jsx)(n.code,{className:"language-lua",children:'-- Example of custom event handler with debug logging\r\nlocal myEvent = NetRay:RegisterEvent("PlayerAction", {\r\n    typeDefinition = { action = "string", data = "table" }\r\n})\r\n\r\nmyEvent.OnServerEvent:Connect(function(player, action, data)\r\n    -- Basic debug logging\r\n    print("[Event] PlayerAction triggered by", player.Name)\r\n    print("Action:", action)\r\n    print("Data:", data)\r\n\r\n    -- More detailed logging\r\n    local args = {...}\r\n    local argsString = ""\r\n    -- Basic serialization of args for printing\r\n    for i, v in ipairs(args) do\r\n        argsString = argsString .. string.format("%s: %s", i, tostring(v))\r\n        if i < #args then\r\n            argsString = argsString .. ", "\r\n        end\r\n    end\r\n    print("[Debug] Event arguments:", argsString)\r\n\r\n    -- Process the event\r\n    processPlayerAction(player, action, data)\r\nend) \n'})}),"\n",(0,t.jsx)(n.h2,{id:"tips-for-debugging",children:"Tips for Debugging"}),"\n",(0,t.jsxs)(n.ol,{children:["\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.strong,{children:"Enable Debug Monitoring:"})," Start with ",(0,t.jsx)(n.code,{children:"NetRay.Debug.EnableMonitoring({ enabled = true })"}),"."]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.strong,{children:"Use GlobalEvent:"})," Connect a listener to ",(0,t.jsx)(n.code,{children:"GlobalEvent"})," to see the general flow of registrations, fires, and receives."]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.strong,{children:"Check for Errors:"})," Monitor ",(0,t.jsx)(n.code,{children:"NetRay.Debug.Error"})," for any internal issues caught by the library."]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.strong,{children:"Validate Types:"})," If using type checking, ensure your definitions match the actual data being sent. Check warnings for validation failures."]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.strong,{children:"Middleware Issues:"})," Add ",(0,t.jsx)(n.code,{children:"print()"})," statements within your middleware functions to see the data at each stage and check if any middleware is incorrectly returning ",(0,t.jsx)(n.code,{children:"false"}),"."]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.strong,{children:"Circuit Breakers:"})," Monitor the ",(0,t.jsx)(n.code,{children:"StateChanged"})," signal of relevant circuit breakers if requests seem blocked unexpectedly. Use ",(0,t.jsx)(n.code,{children:"cb:GetMetrics()"}),"."]}),"\n",(0,t.jsxs)(n.li,{children:[(0,t.jsx)(n.strong,{children:"Client/Server Context:"})," Pay attention to the ",(0,t.jsx)(n.code,{children:"context"}),' ("Client" or "Server") provided in the debug signals to know where the event originated.']}),"\n"]})]})}function g(e={}){const{wrapper:n}={...(0,s.R)(),...e.components};return n?(0,t.jsx)(n,{...e,children:(0,t.jsx)(d,{...e})}):d(e)}},8453:(e,n,r)=>{r.d(n,{R:()=>a,x:()=>o});var i=r(6540);const t={},s=i.createContext(t);function a(e){const n=i.useContext(s);return i.useMemo((function(){return"function"==typeof e?e(n):{...n,...e}}),[n,e])}function o(e){let n;return n=e.disableParentContext?"function"==typeof e.components?e.components(t):e.components||t:a(e.components),i.createElement(s.Provider,{value:n},e.children)}}}]);