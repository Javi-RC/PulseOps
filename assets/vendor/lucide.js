// Exposes the Lucide icon set as `lucide-<name>` utility classes, the same way
// the heroicons plugin does: the SVG becomes a CSS mask, so the icon inherits
// the surrounding text colour instead of carrying its own.
//
// The icon files come from the `lucide` dependency declared in mix.exs.
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

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
      let content = fs.readFileSync(fullPath).toString()
        // Lucide ships its icons with width="24" height="24", which gives the
        // mask image an intrinsic size. A mask does not scale to its box, so at
        // any other size the icon was drawn at 24px and clipped. Heroicons ship
        // without those attributes, which is why they never showed the problem.
        .replace(/\s(width|height)="[^"]*"/g, "")
        .replace(/\s+/g, " ")
        .trim()

      content = encodeURIComponent(content)

      return {
        [`--lucide-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--lucide-${name})`,
        "mask": `var(--lucide-${name})`,
        "mask-repeat": "no-repeat",
        // Belt and braces with the stripped attributes above: the mask now
        // fills whatever box the size utility gives the element.
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
