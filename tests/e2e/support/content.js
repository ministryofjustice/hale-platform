// A site's seeded pages and posts, as seed/import-content.php makes them from
// seed/content/<site>/content.json: an item with `repeat` is that many items,
// with the ID, the slug's and title's number and the date, a day apart,
// counting up from the first. Every item has its date, the seed's default
// where content.json gives none.

const DEFAULT_DATE = "2026-01-05 09:00:00";
const DAY = 24 * 60 * 60 * 1000;

// "2026-01-05 09:00:00", in UTC as the seed's dates are, to milliseconds and back.
const toTime = (date) => Date.parse(`${date.replace(" ", "T")}Z`);
const toDate = (time) => new Date(time).toISOString().slice(0, 19).replace("T", " ");

function seededItems(site) {
  const { items } = require(`../seed/content/${site.key}/content.json`);

  return items.flatMap(({ repeat, date = DEFAULT_DATE, ...item }) =>
    repeat
      ? Array.from({ length: repeat }, (_, i) => ({
          ...item,
          id: item.id + i,
          slug: `${item.slug}-${i + 1}`,
          title: `${item.title} ${i + 1}`,
          date: toDate(toTime(date) + i * DAY),
        }))
      : [{ ...item, date }],
  );
}

module.exports = { seededItems };
