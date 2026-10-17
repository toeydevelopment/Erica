# Fleet dashboard

The dashboard is a local web page that draws the fleet as an org chart that fits one screen.
The firstmate sits on top with a count of every worker by state.
Below it, each second mate is a card, and the firstmate's own ships and scouts share a "Direct crew" card.
Cards that need a look (blocked, then working) come first and glide to their new place when states change.
Messages between mates fly as colored dots from card to card, so you can watch work being dispatched, steered, reported and merged.

![Dashboard on the fixture home, every card expanded](dashboard.png)

## Use it

- **Fit** (the default) collapses every card to a row of worker dots so the whole fleet fits one screen; turn it off for roomier cards.
- **Expand** a card with its arrow, or use Expand and Collapse for all cards, to list its workers with task, latest status and age.
- **Click** a card, a worker dot or a worker row to open its details: role, lead, project, branch, PR, task, latest status and its last 60 messages.
- **Filter** with the search box (mates, tasks, projects, status text), the project menu, the state chips or the counts on the firstmate card, and Hide finished; cards with matches open on their own.
- **Activity** lists messages as they arrive, filterable by kind; with a mate selected it shows only that mate's messages. Click one to open its mate.
- The page follows the system light or dark theme; the moon button cycles auto, dark and light.
- Keys: `/` search, `f` fit, `e` expand all, `c` collapse all, `h` hide finished, `a` activity, `Esc` close.
- View choices are remembered in this browser. On a phone the cards stack in one or two columns and Activity opens as a bottom sheet.

## Open it

Run this from the firstmate checkout:

```sh
FM_HOME=/path/to/home factory/bin/sf-dashboard.sh
```

Then open <http://127.0.0.1:8765/> in a browser.
`FM_HOME` defaults to the checkout itself.
Use `--port N` to pick another port, or `--port 0` to take any free port; the script prints the URL it bound.
The server listens on 127.0.0.1 only and stops on Ctrl-C.
The page needs no network and loads no outside files.

`--once` prints the graph as JSON (schema `sf-dashboard.v1`) and exits, for tests and other tools.

## Requirement: the fleet activity ledger

Message flow comes from the fleet activity ledger described in [`docs/fleet-ledger.md`](../../docs/fleet-ledger.md).
Turn it on by creating the empty file `config/fleet-ledger` in the home.
While it is off, the page shows a banner and builds message flow from each task's `state/<id>.status` lines, so only status messages and steers move.
Steer messages come from each task's steering inbox, so they show up either way.

## What the colors mean

The colored bar on top of each card and its badge show the mate's state.
The states are the ones `bin/fm-crew-state.sh` prints.

| State   | Color  | Meaning |
| ------- | ------ | ------- |
| working | green  | The mate is busy; its card pulses. |
| parked  | grey   | Idle and waiting for work. |
| done    | blue   | Finished its task. |
| blocked | red    | Stuck and needs help from its lead. |
| paused  | orange | Deliberately waiting for something expected to clear. |
| failed  | maroon | The task failed. |
| unknown | slate  | The state could not be read. |

The firstmate has no state of its own in the snapshot, so it shows working while any mate under it is working, and parked otherwise.

Message dots and the history strip use one color per message kind: dispatch indigo, steer purple, status green, PR ready orange, merged blue, cleaned up grey.
Dispatch, steer, merged and cleaned up travel from the lead (the firstmate or a second mate) down to the worker.
Status and PR ready travel up from the worker to its lead.
A dot starts and ends at the worker's row when its card is open, at its dot when collapsed, and at the card's header otherwise.

## Where the data comes from

- Mates, tasks and second mates come from `bin/fm-fleet-snapshot.sh --json`.
  The server runs it in one background thread every 30 seconds, never more than one at a time, and kills its whole process group after 300 seconds.
  Requests never wait for it: they use the last good snapshot, and the header shows its age.
  Until the first snapshot arrives, or when it fails, each mate's state comes from the newest line of its `state/<id>.status`.
- Workers under a second mate come from that second mate's own home (`home=` in its meta): its `state/<id>.meta`, `state/<id>.status` and `data/backlog.md`.
  Their messages come from that home's ledger when it is on, otherwise from its status lines, plus its steering inboxes, and they move between the worker and the second mate.
  A second mate whose home is not on this machine falls back to its summary in the snapshot, without messages.
- Messages come from `state/fleet-ledger.jsonl` and from `state/<id>.inbox/`, both handled and unhandled.
  `/api/fleet` carries only the newest 200; `/api/events?after=<seq>` returns the rest.
- `state/<id>.meta` fills in kind, project, branch and PR when the snapshot lacks them; a second mate's project comes from its `projects=`.

The page polls every 3 seconds.
Each new message animates once, up to four at a time; a burst of more than 24 goes straight to the Activity list.
On first load the page fills Activity with the newest 200 messages and replays the last 6.
Message numbers are positions in time order, not stored ids, and a truncated ledger restarts them.

The dashboard reads only.
It never writes under `state/` or `data/`.
`bin/fm-fleet-snapshot.sh` may refresh its own cached summaries of remote second mates, as its header describes.

## Fixture mode

`--fixture <dir>` reads a recorded home instead of the live one:

- `<dir>/fleet-snapshot.json`: a saved `fm-fleet-snapshot.sh --json` output;
- `<dir>/recorded-state/`: files laid out like `state/`;
- `<dir>/recorded-config/`: files laid out like `config/`;
- a second mate's relative `home=` resolves under `<dir>`, with the same `recorded-state/` and `recorded-data/` names inside.

The folders are not named `state/` and `config/` because the repository ignores those names everywhere.
`factory/tests/fixtures/dashboard/` is the demo: a firstmate, two second mates (one with its home recorded), three ships and a scout in mixed states, with a full dispatch, steer, status, PR ready and merged sequence.

```sh
factory/bin/sf-dashboard.sh --fixture factory/tests/fixtures/dashboard
```

`factory/tests/sf-dashboard.test.sh` runs the same fixture.
