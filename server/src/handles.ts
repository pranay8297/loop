import { randomInt } from 'node:crypto';

// Neutral nature and place words. No people's names.
export const WORDS = [
  'Kite', 'River', 'Cedar', 'Harbor', 'Meadow', 'Pebble', 'Summit', 'Willow', 'Comet', 'Delta',
  'Fern', 'Glacier', 'Hollow', 'Island', 'Juniper', 'Lagoon', 'Maple', 'Nimbus', 'Orchard', 'Prairie',
  'Quarry', 'Ridge', 'Spruce', 'Tide', 'Valley', 'Wave', 'Birch', 'Canyon', 'Dune', 'Ember',
  'Falcon', 'Grove', 'Heath', 'Inlet', 'Lantern', 'Mesa', 'Moss', 'Oasis', 'Pine', 'Reef',
  'Sparrow', 'Thicket', 'Tundra', 'Brook', 'Cliff', 'Dawn', 'Estuary', 'Fjord', 'Glade', 'Hill',
  'Lake', 'Marsh', 'Nova', 'Otter', 'Pond', 'Rain', 'Stone', 'Trail', 'Wren', 'Zephyr',
];

export function newHandle(): string {
  return `${WORDS[randomInt(WORDS.length)]} ${randomInt(10, 100)}`;
}
