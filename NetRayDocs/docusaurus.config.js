// @ts-check
// Note: type annotations allow type checking and IDEs autocompletion

import {themes as prismThemes} from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'NetRay',
  tagline: 'High-Performance Roblox Networking Library',
  favicon: 'img/favicon.ico', // Create a favicon and place it here

  // Set the production url of your site here
  url: 'https://AstaWasTaken.github.io', // CHANGE THIS
  // Set the /<baseUrl>/ pathname under which your site is served
  // For GitHub pages deployment, it is often '/<projectName>/'
  baseUrl: '/NetRay/', // CHANGE THIS if deploying (e.g., repository name)

  // GitHub pages deployment config.
  organizationName: 'AstaWasTaken', // CHANGE THIS - Your GitHub username.
  projectName: 'NetRay', // CHANGE THIS - Your repo name.

  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',

  // Even if you don't use internalization, you can use this field to set useful
  // metadata like html lang. For example, if your site is Chinese, you may want
  // to replace "en" with "zh-Hans".
  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: require.resolve('./sidebars.js'),
          // Point to your repo's edit URL (optional)
          editUrl:
            'https://github.com/AstaWasTaken/NetRay', // CHANGE THIS
        },
        blog: false, // Disable blog if not needed
        /*
        blog: {
          showReadingTime: true,
          editUrl:
            'https://github.com/your-username/NetRayDocs/tree/main/', // CHANGE THIS
        },
        */
        theme: {
          customCss: require.resolve('./src/css/custom.css'),
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      // Replace with your project's social card (optional)
      // image: 'img/docusaurus-social-card.jpg',
      navbar: {
        title: 'NetRay',
        logo: { // Create a logo and place in static/img/
          alt: 'NetRay Logo',
          src: 'img/logo.svg', // Example path
        },
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'docsSidebar', // Matches the ID in sidebars.js
            position: 'left',
            label: 'Documentation',
          },
           {
            href: 'https://github.com/AstaWasTaken/NetRay', // CHANGE THIS - Link to Docs Repo
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              {
                label: 'Getting Started',
                to: '/docs/getting-started',
              },
              {
                label: 'API Reference',
                to: '/docs/api-reference',
              },
            ],
          },
          {
            title: 'Community',
            items: [
              {
                label: 'DevForum Post', // CHANGE THIS
                href: 'https://devforum.roblox.com/t/netray-high-performance-roblox-networking-library/3592849', // Add link to DevForum or other community page
              },
              // Add Discord, Twitter, etc. if applicable
            ],
          },
          {
            title: 'More',
            items: [
              // { label: 'Blog', to: '/blog' }, // Enable if using blog
              {
                label: 'GitHub',
                href: 'https://github.com/AstaWasTaken/NetRay', // CHANGE THIS
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Asta (@TheYusufGamer). Built with Docusaurus.`, // CHANGE THIS
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ['lua'], // Add lua highlighting support
      },
      colorMode: {
          defaultMode: 'dark',
          disableSwitch: true,
          respectPrefersColorScheme: false, // Automatically selects based on OS preference
      },
      // Optional: Add Algolia search or other features
      // algolia: { ... }
    }),
};

export default config;
