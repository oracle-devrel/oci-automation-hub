/* Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. */
/* The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ */

import fs from "node:fs/promises";
import { Workbook } from "@oai/artifact-tool";

const [ordersPath, offersPath] = process.argv.slice(2);
if (!ordersPath || !offersPath) {
  throw new Error("Usage: generate_seed_data.mjs <order_details.csv> <offers.csv>");
}

const csvCell = (value) => {
  const text = value == null ? "" : String(value);
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
};

const writeCsv = async (path, rows) => {
  const text = `${rows.map((row) => row.map(csvCell).join(",")).join("\n")}\n`;
  await fs.writeFile(path, text, "utf8");
};

const importRows = async (path, sheetName) => {
  const text = await fs.readFile(path, "utf8");
  const workbook = await Workbook.fromCSV(text, { sheetName });
  return workbook.worksheets.getItem(sheetName).getUsedRange(true).values;
};

const orders = await importRows(ordersPath, "Orders");
const orderHeader = orders[0].map(String);
const nameIndex = orderHeader.indexOf("Name");
if (nameIndex < 0) {
  orderHeader.push("Name");
  for (const row of orders.slice(1)) row.push("");
}

const sourceOrderRows = orders.slice(1);
if (sourceOrderRows.length < 200) {
  throw new Error(`Expected at least 200 original order rows, found ${sourceOrderRows.length}`);
}
const originalOrders = sourceOrderRows.slice(0, 200).map((row) => row.slice(0, 6));

let nextOrderId = Math.max(...originalOrders.map((row) => Number(row[0]))) + 1;
let randomState = 6686;
const random = () => {
  randomState = (randomState * 1664525 + 1013904223) >>> 0;
  return randomState / 2 ** 32;
};
const pick = (values) => values[Math.floor(random() * values.length)];

const knownCustomers = {
  KEWC50: "Michael Jean",
  EVZ3667: "Legina Andrews",
  NCK6686: "Saketh Nair",
  RGZ9000: "Naveen Chandra",
};
const registrations = [
  "KEWC50", "EVZ3667", "NCK6686", "RGZ9000",
  "TX1234AB", "TX5678CD", "TX9012EF", "TX3456GH", "TX7890IJ",
  "TX2345KL", "TX6789MN", "TX4567OP", "TX8901QR", "TX5555AA",
  "TX2345KL", "TX1234AB", "TX9012EF", "TX5555AA",
  "CA8RPL21", "FLK92MTR", "NYC4821", "AZ7QW552", "GAH3812",
  "ILP9054", "WA6NCK88", "NVX7720", "OHB4509", "PAJ8123",
];
const customerNames = [
  "Aarav Patel", "Aisha Khan", "Alex Morgan", "Amelia Brown",
  "Carlos Rivera", "Charlotte Wilson", "Daniel Kim", "Deepa Rao",
  "Ethan Davis", "Grace Lee", "Harper Taylor", "Isabella Martinez",
  "Jacob Anderson", "James Walker", "Jordan Clark", "Liam Thompson",
  "Maya Shah", "Mia Robinson", "Noah Harris", "Olivia Lewis",
  "Priya Menon", "Rohan Gupta", "Samuel Young", "Sophia Hall",
  "William King", "Zoe Scott",
];
const menuOrders = [
  ["Chicken Quesadilla, Seasoned Fries, Diet Coke", 12.63],
  ["Bacon Cheeseburger (Lettuce, Tomatoes, Onions, Pickles, Challah Bun, Bacon, Seasoned Fries, Med Rare, Cheddar, No Side, Mayo), Ice Latte", 18.95],
  ["BBQ Ribs (Coleslaw, Seasoned Fries), Mint chocochips Icecream", 24.50],
  ["Green Bean Fries, Giant Onion Rings (x3), Chicken Quesadilla (x2), Cheeseburger Sliders", 62.24],
  ["Cheeseburger Classic, Seasoned Fries, Lemonade", 14.48],
  ["Veggie Burger, Sweet Potato Fries, Iced Tea", 13.25],
  ["Classic Burger, Seasoned Fries, Chocolate Milkshake", 15.75],
  ["Chicken Sandwich, Green Bean Fries, Lemonade", 14.20],
  ["Center Cut Sirloin (Mashed Potatoes, Medium), Broccoli", 17.80],
  ["Cheeseburger Sliders, Seasoned Fries", 8.63],
  ["Bucket of Bones, Coleslaw", 20.51],
  ["Friday's Combo, Giant Onion Rings", 22.95],
  ["Chicken Quesadilla (x2), Green Bean Fries", 17.98],
  ["Bacon Cheeseburger, Seasoned Fries, Diet Coke", 16.49],
  ["BBQ Ribs, Coleslaw, Lemonade", 23.75],
];

const generatedOrders = [];
const generatedCustomerByRegistration = new Map(Object.entries(knownCustomers));
for (let index = 0; index < 1796; index += 1) {
  const registration = pick(registrations);
  if (!generatedCustomerByRegistration.has(registration)) {
    generatedCustomerByRegistration.set(registration, pick(customerNames));
  }
  const [items, cost] = pick(menuOrders);
  const dayOffset = Math.floor(random() * 545);
  const date = new Date(Date.UTC(2025, 0, 1 + dayOffset));
  const dateText = [
    String(date.getUTCDate()).padStart(2, "0"),
    String(date.getUTCMonth() + 1).padStart(2, "0"),
    String(date.getUTCFullYear()).slice(-2),
  ].join("/");
  generatedOrders.push([
    nextOrderId++, registration, dateText, items, cost.toFixed(2),
    generatedCustomerByRegistration.get(registration),
  ]);
}

const requiredOrders = [
  [nextOrderId++, "KEWC50", "SYSDATE-5", "Green Bean Fries, Giant Onion Rings (x3), Chicken Quesadilla (x2), Cheeseburger Sliders", "62.24", "Michael Jean"],
  [nextOrderId++, "EVZ3667", "SYSDATE-4", "Bacon Cheeseburger (Lettuce, Tomatoes, Onions, Pickles, Challah Bun, Bacon, Seasoned Fries, Med Rare, Cheddar, No Side, Mayo), Ice Latte", "18.95", "Legina Andrews"],
  [nextOrderId++, "NCK6686", "SYSDATE-3", "Chicken Quesadilla, Seasoned Fries, Diet Coke", "12.63", "Saketh Nair"],
  [nextOrderId++, "RGZ9000", "SYSDATE-2", "BBQ Ribs (Coleslaw, Seasoned Fries), Mint chocochips Icecream", "24.50", "Naveen Chandra"],
];

const finalOrders = [orderHeader, ...originalOrders, ...generatedOrders, ...requiredOrders];
if (finalOrders.length !== 2001) {
  throw new Error(`Expected 2,000 order rows, produced ${finalOrders.length - 1}`);
}
await writeCsv(ordersPath, finalOrders);

const offers = await importRows(offersPath, "Offers");
const existingOffers = offers.slice(1).filter((row) => {
  return Number(String(row[0]).replace("OFR", "")) <= 15;
}).map((row) => {
  const copy = [...row];
  copy[5] = "31/12/27";
  return copy;
});
const additionalOffers = [
  ["OFR016", "Quesadilla Refresh Combo", "Chicken Quesadilla, Seasoned Fries, Diet Coke", "12.63", "10.99", "31/12/27"],
  ["OFR017", "Bacon Burger Latte Combo", "Bacon Cheeseburger, Seasoned Fries, Ice Latte", "18.95", "16.49", "31/12/27"],
  ["OFR018", "Ribs and Mint Treat", "BBQ Ribs, Coleslaw, Seasoned Fries, Mint chocochips Icecream", "24.50", "21.99", "31/12/27"],
  ["OFR019", "Classic Lemonade Meal", "Cheeseburger Classic, Seasoned Fries, Lemonade", "14.48", "12.49", "31/12/27"],
  ["OFR020", "Veggie Fresh Combo", "Veggie Burger, Sweet Potato Fries, Iced Tea", "13.25", "11.75", "31/12/27"],
  ["OFR021", "Shake and Burger Meal", "Classic Burger, Seasoned Fries, Chocolate Milkshake", "15.75", "13.99", "31/12/27"],
  ["OFR022", "Chicken Sandwich Cooler", "Chicken Sandwich, Green Bean Fries, Lemonade", "14.20", "12.79", "31/12/27"],
  ["OFR023", "Sirloin Dinner Special", "Center Cut Sirloin, Mashed Potatoes, Broccoli", "17.80", "15.99", "31/12/27"],
  ["OFR024", "Family Share Box", "Chicken Quesadilla (x2), Cheeseburger Sliders, Giant Onion Rings, Lemonade (x2)", "35.50", "30.99", "31/12/27"],
  ["OFR025", "Late Night Snack Pair", "Cheeseburger Sliders, Seasoned Fries, Ice Latte", "13.58", "11.99", "31/12/27"],
];
await writeCsv(offersPath, [offers[0], ...existingOffers, ...additionalOffers]);

const verifiedOrders = await importRows(ordersPath, "VerifiedOrders");
const verifiedOffers = await importRows(offersPath, "VerifiedOffers");
if (verifiedOrders.length !== 2001 || verifiedOffers.length !== 26) {
  throw new Error("CSV verification failed after writing seed data");
}
const verifiedOrderRows = verifiedOrders.slice(1);
const orderIds = new Set(verifiedOrderRows.map((row) => String(row[0])));
const registrationsSeen = new Map();
for (const row of verifiedOrderRows) {
  const registration = String(row[1]);
  registrationsSeen.set(registration, (registrationsSeen.get(registration) || 0) + 1);
}
if (orderIds.size !== 2000) throw new Error("Order IDs must be unique");
for (const required of requiredOrders) {
  const match = verifiedOrderRows.find((row) => String(row[0]) === String(required[0]));
  if (!match || match.map(String).join("|") !== required.map(String).join("|")) {
    throw new Error(`Required customer order ${required[1]} is missing or changed`);
  }
}
const offerIds = new Set(verifiedOffers.slice(1).map((row) => String(row[0])));
if (offerIds.size !== 25) throw new Error("Offer IDs must be unique");
console.log(JSON.stringify({
  orderRows: 2000,
  offerRows: 25,
  uniqueOrderIds: orderIds.size,
  repeatedRegistrations: [...registrationsSeen.values()].filter((count) => count > 1).length,
}));
