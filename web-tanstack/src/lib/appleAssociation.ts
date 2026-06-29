export function appleAssociation() {
  const env = typeof process !== "undefined" ? process.env : {};
  const teamID = env.APPLE_TEAM_ID ?? "TEAMID";
  const bundleID = env.IOS_BUNDLE_ID ?? "com.mariobalukcic.worldcupstickers";

  return {
    applinks: {
      apps: [],
      details: [
        {
          appID: `${teamID}.${bundleID}`,
          paths: ["/u/*"]
        }
      ]
    }
  };
}
