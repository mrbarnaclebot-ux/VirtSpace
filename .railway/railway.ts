import { defineRailway, project, service } from "railway/iac";

// Whole-project file: a resource omitted here is deleted on apply. Both
// services run the same image; SERVICE_ENTRY (a Railway variable) picks
// server vs worker. Variables stay unmanaged so secrets never live here.
export default defineRailway(() => {
  const build = { buildEnvironment: "V3", builder: "DOCKERFILE", dockerfilePath: "Dockerfile" } as const;

  // ponytail: no preDeploy migrate yet. migrate.ts reads DATABASE_URL (the
  // pgbouncer pooler) and its session advisory lock is unreliable there
  // (HANDOFF pooler incident). Upgrade path: MIGRATE_DATABASE_URL on the
  // direct Neon host, then preDeploy: "node dist/migrate.js" on api only.
  const api = service("api", {
    build,
    healthcheck: "/healthz",
    replicas: { "us-west2": 1 },
  });
  const worker = service("worker", {
    build,
    replicas: { "us-west2": 1 },
  });

  return project("virtspace", {
    variables: { managed: false },
    resources: [api, worker],
  });
});
