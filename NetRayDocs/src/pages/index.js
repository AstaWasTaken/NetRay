import React from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import HomepageFeatures from '@site/src/components/HomepageFeatures';
import Heading from '@theme/Heading';
import Tabs from '@theme/Tabs'; // Import Tabs
import TabItem from '@theme/TabItem'; // Import TabItem
import CodeBlock from '@theme/CodeBlock'; // Import CodeBlock for syntax highlighting

import styles from './index.module.css';

// --- Homepage Header ---
function HomepageHeader() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <header className={clsx('hero hero--primary', styles.heroBanner)}>
      <div className="container">
        {/* Optional: Add logo here if you have one in static/img */}
        {/* <img src="/img/logo.svg" alt="NetRay Logo" className={styles.heroLogo} /> */}
        <Heading as="h1" className="hero__title">
          {siteConfig.title}
        </Heading>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--secondary button--lg" // Use secondary for contrast on primary bg
            to="/docs/intro">
            Get Started Guide →
          </Link>
          {/* Optional: Add a link to GitHub */}
          {/* <Link
            className={clsx("button button--outline button--lg", styles.outlineButton)}
            href="YOUR_GITHUB_REPO_URL">
            View on GitHub
          </Link> */}
        </div>
      </div>
    </header>
  );
}

// --- Simple Code Example Section ---
function CodeExampleSection() {
  return (
    <section className={clsx(styles.sectionPadding, styles.codeSection)}>
      <div className="container">
        <Heading as="h2" className='text--center' style={ { marginBottom: '2rem' }}>Simple & Powerful API</Heading>
        <Tabs groupId="code-examples">
          <TabItem value="server" label="Server-Side">
            <CodeBlock language="lua">
{`-- Server: Register and handle an event
local myEvent = NetRay:RegisterEvent("SimpleGreeting", {
  typeDefinition = { message = "string" }
})

myEvent:OnEvent(function(player, data)
  print(player.Name, "sent:", data.message)

  -- Reply back to just that player
  myEvent:FireClient(player, { message = "Server received: ".. data.message })
end)

print("NetRay Server event handler ready.")`}
            </CodeBlock>
          </TabItem>
          <TabItem value="client" label="Client-Side">
            <CodeBlock language="lua">
{`-- Client: Get event reference and interact
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
end)`}
            </CodeBlock>
          </TabItem>
        </Tabs>
      </div>
    </section>
  );
}


// --- Main Homepage Component ---
export default function Home() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout
      // Title uses template literal for consistency
      title={`${siteConfig.title} | ${siteConfig.tagline}`}
      description="High-Performance Roblox Networking Library featuring automatic optimizations, type safety, circuit breakers, middleware, and more.">
      <HomepageHeader />
      <main>
        {/* Optional small intro paragraph */}
        <section className={clsx(styles.sectionPadding, styles.introTextSection)}>
             <div className="container text--center">
                <p className={styles.introText}>
                    NetRay streamlines Roblox networking with enhanced performance, reliability features like circuit breakers,
                    and a developer-friendly API including type safety and middleware support. Build robust and efficient
                    networked experiences with less boilerplate.
                </p>
             </div>
         </section>

        {/* Feature list remains */}
        <HomepageFeatures />

        {/* Add the new Code Example Section */}
        <CodeExampleSection />

      </main>
    </Layout>
  );
}