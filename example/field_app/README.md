# Accord field: the two-agent demo

Two field agents, Awa and Moussa, work on one dossier. Each card is a separate device with its own
SQLite database (`DriftStorage`) and its own network switch. They sync through a real Accord server.

Try it:

1. Turn Moussa's phone offline (the switch on his card).
2. Edit on both: change the client name, add visits, tick documents, and approve on one phone,
   reject on the other.
3. Turn Moussa back online. Visits add up, documents merge, the latest name wins, and the decision
   shows both answers until someone keeps one. Accord never picks for you.

## Run

The demo talks to the test server in `interop/` (PostgreSQL in Docker, the published
`@accordsync/server`). From the repository root:

```sh
cd interop && docker compose up -d --wait
cd node && npm ci && ACCORD_DATABASE_URL=postgres://accord:accord@localhost:55432/accord node server.mjs
```

Then, with an Android emulator running:

```sh
cd example/field_app
flutter run
```

The emulator reaches your machine at `10.0.2.2`. For a physical phone, pass your machine's address:
`flutter run --dart-define=ACCORD_URL=http://192.168.1.20:8787 --dart-define=ACCORD_TOKEN_URL=http://192.168.1.20:8788`.

The tokens come from the test server's `/token` route. A real app gets them from its own auth;
see the server docs.
