// @ts-check

/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  // Define the structure of your sidebar here
  // By default, Docusaurus generates a sidebar from the docs folder structure
  // To customize:
  docsSidebar: [ // ID must match themeConfig.navbar.items.sidebarId and docs.sidebarPath if manual
    {
      type: 'doc',
      id: 'intro', // Link to docs/intro.md
      label: 'Introduction',
    },
    {
      type: 'doc',
      id: 'getting-started', // Link to docs/getting-started.md
      label: 'Getting Started',
    },
    {
        type: 'doc',
        id: 'configuration', // Link to docs/configuration.md
        label: 'Configuration',
    },
    {
        type: 'category',
        label: 'Core Concepts',
        link: { type: 'generated-index' }, // Optional: auto-generates an overview page
        items: [
            'core-concepts/events',     // Link to docs/core-concepts/events.md
            'core-concepts/requests',   // Link to docs/core-concepts/requests.md
        ],
    },
    {
        type: 'category',
        label: 'Advanced Features',
        link: { type: 'generated-index' },
        items: [
            'advanced-features/middleware',
            'advanced-features/type-checking',
            'advanced-features/circuit-breakers',
            'advanced-features/priorities',
            'advanced-features/optimizations', // Covers Batching & Compression
        ],
    },
    {
        type: 'doc',
        id: 'debugging',
        label: 'Debugging & Monitoring',
    },
    {
        type: 'category',
        label: 'API Reference',
        link: { id: 'api-reference/index' }, // Link to docs/api-reference/index.md
        items: [
            'api-reference/netray',
            'api-reference/serverevent',
            'api-reference/clientevent',
            'api-reference/requestserver',
            'api-reference/requestclient',
            'api-reference/circuitbreaker',
             // Add more API pages here as needed
        ],
    }
  ],

};

export default sidebars;