use std::collections::{HashMap, HashSet};
use std::ops::Index;
use std::path::{Path, PathBuf};
use std::{
    ffi::{c_void, OsStr},
    fs,
    marker::PhantomData,
};

use anyhow::{anyhow, Context, Result};
use rlua::{Function, Lua, MultiValue, Table, UserData, Value};
use simple_log::{error, info, warn, LogConfigBuilder};
use windows::Win32::System::{
    LibraryLoader::GetModuleHandleA,
    Memory::{VirtualProtect, PAGE_EXECUTE_READWRITE, PAGE_PROTECTION_FLAGS},
    ProcessStatus::{GetModuleInformation, MODULEINFO},
    Threading::GetCurrentProcess,
};

proxy_dll::proxy_dll!([d3d9, d3d11, x3daudio1_7], init);

const FIXES_DIR: &str = "fixes";
const CFG_FILE: &str = "bitfix.cfg";
const DEFAULT_CATEGORY: &str = "other";
const DEFAULT_ROLE: &str = "host";
const CATEGORY_ORDER: &[&str] = &["crash", "gameplay", "visual", "other"];

fn init() {
    if let Ok(bin_dir) = setup() {
        info!(
            "bitfix v{}-{} loaded",
            env!("CARGO_PKG_VERSION"),
            env!("GIT_HASH").chars().take(7).collect::<String>()
        );

        unsafe {
            if let Err(e) = patch(bin_dir) {
                error!("{e:#}");
            }
        }
    }
}

fn setup() -> Result<PathBuf> {
    let exe_path = std::env::current_exe()?;
    let bin_dir = exe_path.parent().context("could not find exe parent dir")?;
    let config = LogConfigBuilder::builder()
        .path(bin_dir.join("bitfix.txt").to_str().unwrap()) // TODO why does this not take a path??
        .size(100)
        .roll_count(10)
        .time_format("%Y-%m-%d %H:%M:%S.%f")
        .level("debug")
        .output_file()
        .build();
    simple_log::new(config).map_err(|e| anyhow!("{e}"))?;
    Ok(bin_dir.to_path_buf())
}

unsafe fn patch(bin_dir: PathBuf) -> Result<()> {
    let module = GetModuleHandleA(None).context("could not find main module")?;
    let process = GetCurrentProcess();

    let mut mod_info = MODULEINFO::default();
    GetModuleInformation(
        process,
        module,
        &mut mod_info as *mut _,
        std::mem::size_of::<MODULEINFO>() as u32,
    );

    let mut memory = RawMemory::default();
    memory.map_page(
        mod_info.lpBaseOfDll as usize,
        std::slice::from_raw_parts_mut(
            mod_info.lpBaseOfDll as *mut u8,
            mod_info.SizeOfImage as usize,
        ),
    );

    let fixes_dir = bin_dir.join(FIXES_DIR);
    let cfg_path = bin_dir.join(CFG_FILE);

    info!("loading fix files from {}", fixes_dir.display());
    let files = load_lua_files(&fixes_dir)?;
    info!("found {} fix file(s)", files.len());

    exec_patches(&mut memory, files, Some(&cfg_path))?;
    info!("done");

    Ok(())
}

trait Memory<'memory>: Index<usize, Output = u8> {
    fn pages(&self) -> usize;
    fn page(&self, index: usize) -> &Page;
    fn page_mut<'s>(&'s mut self, index: usize) -> &'s mut Page<'memory>;
    fn write(&mut self, address: usize, data: u8);
}

struct MatchContext<'wrapper, 'memory, M: Memory<'memory>> {
    address: usize,
    index: usize,
    memory: &'wrapper mut M,
    _phantom: PhantomData<&'memory M>,
}

impl<'memory, M: Memory<'memory>> UserData for MatchContext<'_, 'memory, M> {
    fn add_methods<'lua, T: rlua::UserDataMethods<'lua, Self>>(methods: &mut T) {
        methods.add_method("address", |_, this: &Self, ()| Ok(this.address));
        methods.add_method("index", |_, this: &Self, ()| Ok(this.index));
        methods.add_meta_method(rlua::MetaMethod::Index, |_, this: &Self, index: usize| {
            Ok(this.memory[index])
        });
        methods.add_meta_method_mut(
            rlua::MetaMethod::NewIndex,
            |_, this: &mut Self, (index, value): (usize, u8)| {
                this.memory.write(index, value);
                Ok(())
            },
        );
    }
}

#[derive(Debug)]
struct Page<'memory> {
    address: usize,
    memory: &'memory mut [u8],
}

#[derive(Debug, Default)]
struct RawMemory<'memory> {
    pages: Vec<Page<'memory>>,
}
impl<'memory> RawMemory<'memory> {
    fn map_page(&mut self, address: usize, memory: &'memory mut [u8]) {
        self.pages.push(Page { address, memory });
    }
}
impl<'memory> Memory<'memory> for RawMemory<'memory> {
    fn pages(&self) -> usize {
        self.pages.len()
    }
    fn page(&self, index: usize) -> &Page {
        &self.pages[index]
    }
    fn page_mut<'s>(&'s mut self, index: usize) -> &'s mut Page<'memory> {
        &mut self.pages[index]
    }
    fn write(&mut self, index: usize, data: u8) {
        info!("writing {data:02X?} to {index:X?}");
        for Page { address, memory } in &mut self.pages {
            if index >= *address && index < *address + memory.len() {
                let offset = index - *address;
                let write_mem = &mut memory[offset..offset + 1];
                let mut old: PAGE_PROTECTION_FLAGS = Default::default();
                unsafe {
                    VirtualProtect(
                        write_mem.as_ptr() as *const c_void,
                        write_mem.len(),
                        PAGE_EXECUTE_READWRITE,
                        &mut old,
                    );
                }

                write_mem[0] = data;

                unsafe {
                    VirtualProtect(
                        write_mem.as_ptr() as *const c_void,
                        write_mem.len(),
                        old,
                        &mut old,
                    );
                }
                return;
            }
        }
        panic!("out of bounds")
    }
}
impl Index<usize> for RawMemory<'_> {
    type Output = u8;
    fn index(&self, index: usize) -> &Self::Output {
        for Page { address, memory } in &self.pages {
            if index >= *address && index < *address + memory.len() {
                return &memory[index - address];
            }
        }
        panic!("out of bounds")
    }
}

struct LuaFile {
    file_stem: String,
    body: String,
}

#[derive(Debug, Clone)]
struct FixMeta {
    file_stem: String,
    description: String,
    category: String,
    role: String,
    default_enabled: bool,
}

fn role_tag(role: &str) -> String {
    match role {
        "host" => "[host-side]".to_string(),
        "client" => "[client-side]".to_string(),
        other => format!("[{}]", other),
    }
}

fn load_lua_files<P: AsRef<Path>>(path: P) -> Result<Vec<LuaFile>> {
    let mut files = vec![];
    match fs::read_dir(&path) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                let p = entry.path();
                if p.extension() == Some(OsStr::new("lua")) && p.is_file() {
                    let file_stem = p
                        .file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_string();
                    let body = fs::read_to_string(&p)
                        .with_context(|| format!("reading {}", p.display()))?;
                    files.push(LuaFile { file_stem, body });
                }
            }
        }
        Err(e) => {
            warn!(
                "unable to read fixes dir {}: {}. No fixes will be applied.",
                path.as_ref().display(),
                e
            );
        }
    }
    files.sort_by(|a, b| a.file_stem.cmp(&b.file_stem));
    Ok(files)
}

fn parse_cfg(text: &str) -> HashMap<String, bool> {
    let mut map = HashMap::new();
    for line in text.lines() {
        let line = match line.split_once('#') {
            Some((before, _)) => before,
            None => line,
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim().to_ascii_lowercase();
        let parsed = match value.as_str() {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        };
        if let (false, Some(v)) = (key.is_empty(), parsed) {
            map.insert(key.to_string(), v);
        }
    }
    map
}

fn category_title(category: &str) -> String {
    match category {
        "crash" => "Crash Fixes".into(),
        "gameplay" => "Gameplay".into(),
        "visual" => "Visual".into(),
        "other" => "Other".into(),
        s => {
            let mut c = s.chars();
            match c.next() {
                None => String::new(),
                Some(first) => first.to_uppercase().collect::<String>() + c.as_str(),
            }
        }
    }
}

fn render_cfg(metas: &[FixMeta], existing: &HashMap<String, bool>) -> String {
    let mut buf = String::new();
    buf.push_str("# bitfix.cfg: edit true/false to toggle fixes.\n");
    buf.push_str("# This file is regenerated on each launch; custom comments will be removed.\n");
    buf.push_str("# Entries are grouped by the category declared in each fix's .lua file.\n");
    buf.push_str("#\n");
    buf.push_str("# Role tags:\n");
    buf.push_str("#   [host-side]   = effective only when you host the lobby\n");
    buf.push_str("#   [client-side] = effective on your machine regardless of host\n");
    buf.push('\n');

    let mut by_cat: HashMap<&str, Vec<&FixMeta>> = HashMap::new();
    for m in metas {
        by_cat.entry(m.category.as_str()).or_default().push(m);
    }

    let mut ordered: Vec<&str> = CATEGORY_ORDER
        .iter()
        .copied()
        .filter(|c| by_cat.contains_key(c))
        .collect();
    let mut extras: Vec<&str> = by_cat
        .keys()
        .copied()
        .filter(|c| !CATEGORY_ORDER.contains(c))
        .collect();
    extras.sort();
    ordered.extend(extras);

    for cat in ordered {
        let mut entries = by_cat.remove(cat).unwrap();
        entries.sort_by(|a, b| a.file_stem.cmp(&b.file_stem));
        buf.push_str(&format!("# === {} ===\n", category_title(cat)));
        let key_pad = entries.iter().map(|m| m.file_stem.len()).max().unwrap_or(0);
        for m in entries {
            let v = existing
                .get(&m.file_stem)
                .copied()
                .unwrap_or(m.default_enabled);
            let v_str = if v { "true " } else { "false" };
            let pad = " ".repeat(key_pad - m.file_stem.len());
            let tag = role_tag(&m.role);
            let comment = if m.description.is_empty() {
                tag
            } else {
                format!("{} {}", tag, m.description)
            };
            buf.push_str(&format!(
                "{}{} = {}  # {}\n",
                m.file_stem, pad, v_str, comment
            ));
        }
        buf.push('\n');
    }

    let known: HashSet<&str> = metas.iter().map(|m| m.file_stem.as_str()).collect();
    let mut orphans: Vec<(&String, &bool)> = existing
        .iter()
        .filter(|(k, _)| !known.contains(k.as_str()))
        .collect();
    if !orphans.is_empty() {
        orphans.sort_by(|a, b| a.0.cmp(b.0));
        buf.push_str("# === Removed / not found ===\n");
        buf.push_str("# These entries have no matching .lua in fixes/.\n");
        buf.push_str("# Restore the .lua to re-enable, or delete these lines to clean up.\n");
        for (k, v) in orphans {
            buf.push_str(&format!("# {} = {}\n", k, v));
        }
        buf.push('\n');
    }

    buf
}

fn exec_patches<'wrapper, 'memory>(
    memory: &'wrapper mut (impl Memory<'memory> + 'memory),
    files: Vec<LuaFile>,
    cfg_path: Option<&Path>,
) -> Result<()> {
    struct ActivePatch<'lua> {
        fix_stem: String,
        label: String,
        pattern: String,
        function: Function<'lua>,
    }

    Lua::new().context(|lua| -> Result<()> {
        info!("entered lua context");

        let print = lua.create_function(|lua, args: MultiValue| {
            let tostring = lua.globals().get::<_, Function>("tostring")?;
            let mut buf = String::new();
            let mut iter = args.into_iter().peekable();
            while let Some(arg) = iter.next() {
                let str = tostring.call::<_, String>(arg)?;
                buf.push_str(&str);
                if iter.peek().is_some() {
                    buf.push('\t');
                }
            }
            info!("lua: {buf}");
            Ok(())
        })?;
        lua.globals().set("print", print)?;

        let mut metas: Vec<FixMeta> = vec![];
        let mut all_patches: Vec<ActivePatch> = vec![];

        for file in &files {
            let table = lua
                .load(&file.body)
                .eval::<Table>()
                .with_context(|| format!("evaluating {}.lua", file.file_stem))?;

            let description = table.get::<_, String>("description").unwrap_or_default();
            let category = table
                .get::<_, String>("category")
                .unwrap_or_else(|_| DEFAULT_CATEGORY.to_string());
            let role = table
                .get::<_, String>("role")
                .unwrap_or_else(|_| DEFAULT_ROLE.to_string());
            let default_enabled = table.get::<_, bool>("default").unwrap_or(false);

            if table.get::<_, Value>("name").is_err() {
                warn!(
                    "{}.lua has no metadata fields; treating as untyped (default=false, category=other)",
                    file.file_stem
                );
            }

            metas.push(FixMeta {
                file_stem: file.file_stem.clone(),
                description,
                category,
                role,
                default_enabled,
            });

            let patches_table: Table = table.get("patches").with_context(|| {
                format!("{}.lua: missing required 'patches' table", file.file_stem)
            })?;

            for pair in patches_table.pairs::<Value, Table>() {
                let (label_val, entry) = pair?;
                let label = lua
                    .coerce_string(label_val)?
                    .and_then(|s| s.to_str().ok().map(|s| s.to_string()))
                    .unwrap_or_default();
                let pattern = entry.get::<_, String>("pattern")?;
                let function = entry.get::<_, Function>("match")?;
                all_patches.push(ActivePatch {
                    fix_stem: file.file_stem.clone(),
                    label,
                    pattern,
                    function,
                });
            }
        }

        let existing: HashMap<String, bool> = cfg_path
            .and_then(|p| fs::read_to_string(p).ok())
            .map(|t| parse_cfg(&t))
            .unwrap_or_default();

        let enabled_state: HashMap<String, bool> = metas
            .iter()
            .map(|m| {
                (
                    m.file_stem.clone(),
                    existing
                        .get(&m.file_stem)
                        .copied()
                        .unwrap_or(m.default_enabled),
                )
            })
            .collect();

        if let Some(p) = cfg_path {
            let rendered = render_cfg(&metas, &existing);
            if let Err(e) = fs::write(p, &rendered) {
                warn!("failed to write {}: {}", p.display(), e);
            } else {
                info!("wrote {}", p.display());
            }
        }

        let active: Vec<&ActivePatch> = all_patches
            .iter()
            .filter(|p| *enabled_state.get(&p.fix_stem).unwrap_or(&false))
            .collect();

        for m in &metas {
            let on = *enabled_state.get(&m.file_stem).unwrap_or(&false);
            info!(
                "fix {} [{}/{}] = {}",
                m.file_stem,
                m.category,
                m.role,
                if on { "ENABLED" } else { "disabled" }
            );
        }

        if active.is_empty() {
            info!("no fixes enabled. See bitfix.cfg to turn some on.");
            return Ok(());
        }

        let patterns = active
            .iter()
            .map(|c| patternsleuth_scanner::Pattern::new(&c.pattern))
            .collect::<Result<Vec<_>>>()?;
        let pattern_refs = patterns.iter().collect::<Vec<_>>();

        for i in 0..memory.pages() {
            info!("scanning page: {i}");
            let map = memory.page(i);
            let results =
                patternsleuth_scanner::scan_pattern(&pattern_refs, map.address, map.memory);
            info!("scan results: {results:X?}");

            for (config, addresses) in active.iter().zip(results) {
                if addresses.is_empty() {
                    warn!(
                        "no pattern match for {}/{}",
                        config.fix_stem, config.label
                    );
                }
                for (index, address) in addresses.iter().enumerate() {
                    lua.scope(|lua| {
                        let ctx = lua.create_nonstatic_userdata(MatchContext {
                            index,
                            address: *address,
                            memory,
                            _phantom: PhantomData,
                        })?;
                        info!(
                            "calling patcher {}/{}: on {address:X?}",
                            config.fix_stem, config.label,
                        );
                        config.function.call::<_, ()>(ctx)
                    })?;
                }
            }
        }

        Ok(())
    })
}

#[cfg(test)]
mod test {
    use super::*;

    #[derive(Debug, Default)]
    struct VirtualMemory<'memory> {
        pages: Vec<Page<'memory>>,
    }
    impl<'memory> VirtualMemory<'memory> {
        fn map_page(&mut self, address: usize, memory: &'memory mut [u8]) {
            self.pages.push(Page { address, memory });
        }
    }
    impl<'memory> Memory<'memory> for VirtualMemory<'memory> {
        fn pages(&self) -> usize {
            self.pages.len()
        }
        fn page(&self, index: usize) -> &Page {
            &self.pages[index]
        }
        fn page_mut<'s>(&'s mut self, index: usize) -> &'s mut Page<'memory> {
            &mut self.pages[index]
        }
        fn write(&mut self, index: usize, data: u8) {
            for Page { address, memory } in &mut self.pages {
                if index >= *address && index < *address + memory.len() {
                    memory[index - *address] = data;
                    return;
                }
            }
            panic!("out of bounds")
        }
    }
    impl<'memory> Index<usize> for VirtualMemory<'memory> {
        type Output = u8;
        fn index(&self, index: usize) -> &Self::Output {
            for Page { address, memory } in &self.pages {
                if index >= *address && index < *address + memory.len() {
                    return &memory[index - address];
                }
            }
            panic!("out of bounds")
        }
    }

    #[test]
    fn test_lua() -> Result<()> {
        let config = LogConfigBuilder::builder()
            .level("debug")
            .output_console()
            .build();
        simple_log::new(config).ok();

        let base = 100;
        let mut data = [
            0x00, 0x00, 0x00, 0x00, 0x10, 0x20, 0x99, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00,
        ];
        let mut memory = VirtualMemory::default();
        memory.map_page(base, &mut data);

        let files = vec![LuaFile {
            file_stem: "test".to_string(),
            body: r#"
            return {
                name = "Test Fix",
                description = "test fix for unit test",
                category = "other",
                default = true,
                patches = {
                    patch1 = {
                        pattern = '10 20 ?? 30',
                        match = function(ctx)
                            print(string.format('match found! %s', ctx:address()))
                            print(string.format('first byte: %s', ctx[ctx:address()]))
                            ctx[ctx:address()] = 0x25
                            print('patched')
                        end
                    },
                    patch2 = {
                        pattern = '00',
                        match = function(ctx)
                            print(string.format('match index; %s', ctx:index()))
                        end
                    }
                }
            }
            "#
            .to_string(),
        }];

        exec_patches(&mut memory, files, None)?;

        assert_eq!(
            memory.page(0).memory,
            [0x00, 0x00, 0x00, 0x00, 0x25, 0x20, 0x99, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00,]
        );

        Ok(())
    }

    #[test]
    fn test_cfg_roundtrip() {
        let metas = vec![
            FixMeta {
                file_stem: "alpha".into(),
                description: "first".into(),
                category: "crash".into(),
                role: "host".into(),
                default_enabled: true,
            },
            FixMeta {
                file_stem: "beta".into(),
                description: "second".into(),
                category: "gameplay".into(),
                role: "client".into(),
                default_enabled: false,
            },
            FixMeta {
                file_stem: "gamma".into(),
                description: "third".into(),
                category: "crash".into(),
                role: "host".into(),
                default_enabled: true,
            },
        ];

        // No prior cfg: defaults populate.
        let empty = HashMap::new();
        let out = render_cfg(&metas, &empty);
        assert!(out.contains("=== Crash Fixes ==="));
        assert!(out.contains("=== Gameplay ==="));
        // Role tags should render in the inline comments.
        assert!(out.contains("[host-side] first"));
        assert!(out.contains("[client-side] second"));
        // Defaults reflected
        let parsed = parse_cfg(&out);
        assert_eq!(parsed.get("alpha"), Some(&true));
        assert_eq!(parsed.get("beta"), Some(&false));
        assert_eq!(parsed.get("gamma"), Some(&true));

        // User flipped beta on; rewrite preserves it.
        let mut user = parsed.clone();
        user.insert("beta".into(), true);
        let out2 = render_cfg(&metas, &user);
        let parsed2 = parse_cfg(&out2);
        assert_eq!(parsed2.get("beta"), Some(&true));
        assert_eq!(parsed2.get("alpha"), Some(&true));

        // Orphan handling: cfg entry without a matching meta is commented out.
        let mut with_orphan = user.clone();
        with_orphan.insert("ghost".into(), true);
        let out3 = render_cfg(&metas, &with_orphan);
        assert!(out3.contains("=== Removed / not found ==="));
        assert!(out3.contains("# ghost = true"));
        // Orphan parses back to nothing (because it's commented).
        let parsed3 = parse_cfg(&out3);
        assert_eq!(parsed3.get("ghost"), None);
    }

    #[test]
    fn test_parse_cfg_tolerant() {
        let text = "
            # leading comment
            alpha = true
            beta=false  # inline comment
              gamma  =  TRUE
            # commented = true
            invalid line
            empty =
        ";
        let m = parse_cfg(text);
        assert_eq!(m.get("alpha"), Some(&true));
        assert_eq!(m.get("beta"), Some(&false));
        assert_eq!(m.get("gamma"), Some(&true));
        assert_eq!(m.get("commented"), None);
        assert_eq!(m.get("empty"), None);
    }
}
