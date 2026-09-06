// Exposes the Lucide icon set as `lucide-<name>` utility classes, the same way
// the heroicons plugin does: the SVG becomes a CSS mask, so the icon inherits
// the surrounding text colour instead of carrying its own.
//
// The icon files come from the `lucide` dependency declared in mix.exs.
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

// Lucide ships its icons with width="24" height="24" on the root <svg>, which
// gives the mask image an intrinsic size. A CSS mask does not scale to its box,
// so the icon would paint at 24px whatever size utility was on the element.
// Heroicons ship without those attributes, which is why they never showed it.
//
// Only the opening tag is touched. Many Lucide icons are drawn out of <rect>
// elements — `layout-dashboard` and `server` are nothing but rects — and
// stripping width/height from those collapses the shapes to nothing.
function stripRootDimensions(svg) {
  return svg.replace(/<svg[^>]*>/, tag => tag.replace(/\s(width|height)="[^"]*"/g, ""))
}

module.exports = plugin(function({matchComponents, theme}) {
  let iconsDir = path.join(__dirname, "../../deps/lucide/icons")
  let values = {}

  fs.readdirSync(iconsDir)
    .filter(file => file.endsWith(".svg"))
    .forEach(file => {
      let name = path.basename(file, ".svg")
      values[name] = {name, fullPath: path.join(iconsDir, file)}
    })

  matchComponents({
    "lucide": ({name, fullPath}) => {
      let svg = fs.readFileSync(fullPath).toString().replace(/\s+/g, " ").trim()
      let content = encodeURIComponent(stripRootDimensions(svg))

      return {
        [`--lucide-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--lucide-${name})`,
        "mask": `var(--lucide-${name})`,
        "mask-repeat": "no-repeat",
        // Belt and braces with the stripped attributes above: the mask fills
        // whatever box the size utility gives the element.
        "-webkit-mask-size": "100% 100%",
        "mask-size": "100% 100%",
        "-webkit-mask-position": "center",
        "mask-position": "center",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "flex-shrink": "0",
        "width": theme("spacing.5"),
        "height": theme("spacing.5")
      }
    }
  }, {values})
})
