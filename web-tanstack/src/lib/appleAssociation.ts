export function appleAssociation() {
  const env: Record<string, string | undefined> = typeof process !== "undefined" ? process.env : {};
  const teamID = env.APPLE_TEAM_ID ?? "RJS3R23FND";
  const bundleID = env.IOS_BUNDLE_ID ?? "com.sstikr.worldcupstickers";

  return {
    applinks: {
      apps: [],
      details: [
        {
          appID: `${teamID}.${bundleID}`,
          paths: ["/u/*"]
        }
      ]
    },
    webcredentials: {
      apps: [`${teamID}.${bundleID}`]
    }
  };
}
