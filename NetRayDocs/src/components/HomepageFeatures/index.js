import React from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

const FeatureList = [
  {
    title: 'Optimized Performance',
    icon: '⚡', // Placeholder icon
    // Svg: require('@site/static/img/undraw_performance.svg').default, // Uncomment if using SVGs
    description: (
      <>
        Automatic event batching, efficient binary serialization, and intelligent
        compression reduce network load and improve responsiveness.
      </>
    ),
  },
  {
    title: 'Enhanced Reliability',
    icon: '🔒', // Placeholder icon
    // Svg: require('@site/static/img/undraw_reliable.svg').default,
    description: (
      <>
        Built-in Circuit Breakers prevent cascading failures, while robust error handling
        and timeouts make your networking more resilient.
      </>
    ),
  },
  {
    title: 'Type Safety & Validation',
    icon: '🛡️', // Placeholder icon
    // Svg: require('@site/static/img/undraw_safe.svg').default,
    description: (
      <>
        Define data structures for your events and requests. NetRay automatically validates
        payloads, catching errors early in development.
      </>
    ),
  },
  {
      title: 'Flexible Middleware',
      icon: '⚙️', // Placeholder icon
     // Svg: require('@site/static/img/undraw_flexible.svg').default,
     description: (
       <>
        Intercept, modify, or block network traffic using a powerful middleware system.
        Implement logging, rate limiting, or custom validation with ease.
       </>
     ),
   },
   {
       title: 'Modern Developer Experience',
       icon: '🚀', // Placeholder icon
       // Svg: require('@site/static/img/undraw_developer.svg').default,
       description: (
        <>
         Clean API using Promises for asynchronous requests, clear event handling patterns,
         and priority queues simplify complex networking code.
         </>
        ),
    },
    {
        title: 'Built-in Monitoring',
        icon: '📊', // Placeholder icon
        // Svg: require('@site/static/img/undraw_monitor.svg').default,
        description: (
          <>
          Debug signals provide visibility into internal events, errors, and potentially
          network traffic, aiding optimization and troubleshooting.
          </>
         ),
     },
];

// Updated Feature component to include icon
function Feature({ Svg, icon, title, description }) {
  return (
    <div className={clsx('col col--4')}>
      <div className={clsx("text--center", styles.featureContent)}>
        {/* Render SVG if provided, otherwise render icon span */}
        {Svg ? (
          <Svg className={styles.featureSvg} role="img" />
        ) : (
          icon && <span className={styles.featureIcon}>{icon}</span>
        )}
        <Heading as="h3" className={styles.featureTitle}>{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  );
}


export default function HomepageFeatures() {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}