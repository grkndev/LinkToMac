const { withGradleProperties } = require('expo/config-plugins');

/**
 * Raise the Gradle JVM heap so the release dex-merge (D8) doesn't OOM ("D8:
 * java.lang.OutOfMemoryError: Java heap space" during :app:mergeDexRelease) on
 * this RN 0.85 app. The managed prebuild regenerates android/gradle.properties on
 * every build, so we patch `org.gradle.jvmargs` here rather than editing the file
 * (which wouldn't survive prebuild). Default 4 GB heap + 1 GB metaspace — enough
 * for the merge, conservative on a 16 GB machine. Override via the `xmx` option.
 */
module.exports = function withGradleHeap(config, { xmx = '4g' } = {}) {
  return withGradleProperties(config, (cfg) => {
    const key = 'org.gradle.jvmargs';
    const value = `-Xmx${xmx} -XX:MaxMetaspaceSize=1g -XX:+HeapDumpOnOutOfMemoryError -Dfile.encoding=UTF-8`;
    const existing = cfg.modResults.find((p) => p.type === 'property' && p.key === key);
    if (existing) existing.value = value;
    else cfg.modResults.push({ type: 'property', key, value });
    return cfg;
  });
};
