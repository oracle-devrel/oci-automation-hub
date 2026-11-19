/* Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. */
/* The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ */

import fs from "node:fs/promises";
import { Workbook } from "@oai/artifact-tool";

const [ordersPath, offersPath, previewPath] = process.argv.slice(2);
const orders = await Workbook.fromCSV(await fs.readFile(ordersPath, "utf8"), {
  sheetName: "Orders",
});
const offers = await Workbook.fromCSV(await fs.readFile(offersPath, "utf8"), {
  sheetName: "Offers",
});

const orderCheck = await orders.inspect({
  kind: "region",
  sheetId: "Orders",
  range: "A1:F8",
  maxChars: 5000,
});
const offerCheck = await offers.inspect({
  kind: "region",
  sheetId: "Offers",
  range: "A14:F26",
  maxChars: 7000,
});
console.log(orderCheck.ndjson);
console.log(offerCheck.ndjson);

const preview = await orders.render({
  sheetName: "Orders",
  range: "A1:F12",
  scale: 1,
  format: "png",
});
await fs.writeFile(previewPath, new Uint8Array(await preview.arrayBuffer()));
