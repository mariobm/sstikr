import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  component: HomePage
});

function HomePage() {
  return (
    <main className="page">
      <section className="panel">
        <div className="eyebrow">World Cup Stickers</div>
        <h1>Track every sticker and trade duplicates.</h1>
        <p>
          Scan the back of each sticker, confirm the country code and number, then share duplicates when sync is enabled.
        </p>
        <a className="button" href="/u/demo">
          View profile preview
        </a>
      </section>
    </main>
  );
}
