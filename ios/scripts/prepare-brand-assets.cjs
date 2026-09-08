// Render the upstream vector mark without redrawing its geometry.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Brand', 'codex-color.svg'), 'utf8');
const backgrounds = source.match(/<path\b[^>]*fill="#fff"[^>]*><\/path>/g) || [];
if (backgrounds.length !== 1) throw new Error('Unexpected upstream logo structure');
const colorPath = source.match(/<path\b[^>]*fill="url\([^>]+><\/path>/)?.[0];
const colorGeometry = colorPath?.match(/\bd="([^"]+)"/)?.[1];
if (!colorGeometry || !colorPath || !colorGeometry.includes('z')) throw new Error('Missing source silhouette');
// The original terminal counters reveal the white tile. Preserve those white
// counters on the transparent variant by reusing its exact outer contour.
const silhouette = colorGeometry.slice(0, colorGeometry.indexOf('z') + 1);
const mark = source.replace(backgrounds[0], '')
  .replace(colorPath, `<path d="${silhouette}" fill="#fff"></path>${colorPath}`)
  .replace('viewBox="0 0 24 24"', 'viewBox="3 3 18 18"');
const assets = path.join(root, 'CodexPhoneNotifier', 'Assets.xcassets');
function catalog(folder, content) {
  fs.mkdirSync(folder, {recursive:true});
  fs.writeFileSync(path.join(folder, 'Contents.json'), JSON.stringify(content, null, 2) + '\n');
}
async function main() {
  catalog(assets, {info:{author:'xcode',version:1}});
  const markDir = path.join(assets, 'CodexMark.imageset');
  catalog(markDir, {images:[1,2,3].map(scale=>({idiom:'universal',filename:`mark@${scale}x.png`,scale:`${scale}x`})),info:{author:'xcode',version:1}});
  for(const scale of [1,2,3]) await sharp(Buffer.from(mark), {density:600}).resize(96*scale,96*scale).png().toFile(path.join(markDir, `mark@${scale}x.png`));
  const iconDir = path.join(assets, 'AppIcon.appiconset');
  catalog(iconDir, {images:[{idiom:'universal',platform:'ios',size:'1024x1024',filename:'AppIcon.png'}],info:{author:'xcode',version:1}});
  await sharp(Buffer.from(source), {density:1200}).resize(1024,1024).flatten({background:'#ffffff'}).removeAlpha().png().toFile(path.join(iconDir,'AppIcon.png'));
  console.log('Rendered CodexMark 1x/2x/3x and opaque 1024px AppIcon from upstream SVG.');
}
main().catch(error=>{ console.error(error.message); process.exitCode=1; });
