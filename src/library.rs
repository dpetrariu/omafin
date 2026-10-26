//! Library requests, trimmed to what the window shows. Every id is validated
//! before it reaches a URL; every response is reshaped here so the UI never
//! depends on Jellyfin's full item format.

use serde_json::{Map, Value, json};

use crate::app::App;
use crate::error::{Error, Result};
use crate::jellyfin::{TICKS_PER_SECOND, q, require_id, valid_id};

/// Fields every card needs; the server leaves most others out unless asked.
const CARD_FIELDS: &str = "PrimaryImageAspectRatio,ChildCount,RecursiveItemCount,ProductionYear,EndDate,Status";
const CARD_IMAGES: &str = "EnableImageTypes=Primary,Backdrop,Thumb,Logo&ImageTypeLimit=1";

pub fn str_param<'a>(params: &'a Value, name: &str) -> &'a str {
    params.get(name).and_then(|v| v.as_str()).unwrap_or("")
}

fn bool_param(params: &Value, name: &str) -> Option<bool> {
    params.get(name).and_then(|v| v.as_bool())
}

fn u64_param(params: &Value, name: &str) -> Option<u64> {
    params.get(name).and_then(|v| v.as_u64().or_else(|| v.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64)))
}

fn id_param<'a>(params: &'a Value, name: &str) -> Result<&'a str> {
    require_id(str_param(params, name))
}

pub fn user_id(app: &App) -> Result<String> {
    let id = app.settings().user_id;
    if id.is_empty() { Err(Error::not_configured()) } else { Ok(id) }
}

// ---------------------------------------------------------------- shaping

fn text(item: &Value, key: &str) -> Value {
    match item.get(key).and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => Value::String(s.to_string()),
        _ => Value::Null,
    }
}

fn number(item: &Value, key: &str) -> Value {
    item.get(key).filter(|v| v.is_number()).cloned().unwrap_or(Value::Null)
}

fn seconds(ticks: Option<&Value>) -> Value {
    match ticks.and_then(|v| v.as_i64()) {
        Some(t) if t > 0 => json!((t as f64 / TICKS_PER_SECOND as f64).round()),
        _ => Value::Null,
    }
}

fn image(id: Option<&str>, tag: Option<&str>) -> Value {
    match (id, tag) {
        (Some(id), Some(tag)) if valid_id(id) && !tag.is_empty() => json!({ "id": id, "tag": tag }),
        _ => Value::Null,
    }
}

fn first_tag(item: &Value, key: &str) -> Option<String> {
    item.get(key).and_then(|v| v.as_array()).and_then(|a| a.first()).and_then(|v| v.as_str()).map(String::from)
}

fn own_tag(item: &Value, kind: &str) -> Option<String> {
    item.get("ImageTags").and_then(|t| t.get(kind)).and_then(|v| v.as_str()).map(String::from)
}

/// The pictures a card or a page can draw, each as the item that owns the
/// picture and its tag. Episodes and seasons borrow the show's backdrop and
/// logo; the window never works that out itself.
fn images(item: &Value) -> Value {
    let id = item.get("Id").and_then(|v| v.as_str());
    let s = |k: &str| item.get(k).and_then(|v| v.as_str());
    let primary = image(id, own_tag(item, "Primary").as_deref());
    let backdrop = match first_tag(item, "BackdropImageTags") {
        Some(tag) => image(id, Some(&tag)),
        None => image(s("ParentBackdropItemId"), first_tag(item, "ParentBackdropImageTags").as_deref()),
    };
    let thumb = match own_tag(item, "Thumb") {
        Some(tag) => image(id, Some(&tag)),
        None => image(s("ParentThumbItemId"), s("ParentThumbImageTag")),
    };
    let logo = match own_tag(item, "Logo") {
        Some(tag) => image(id, Some(&tag)),
        None => image(s("ParentLogoItemId"), s("ParentLogoImageTag")),
    };
    let series = image(s("SeriesId"), s("SeriesPrimaryImageTag"));
    json!({ "primary": primary, "backdrop": backdrop, "thumb": thumb, "logo": logo, "series": series })
}

fn user_data(item: &Value) -> Value {
    let data = item.get("UserData").cloned().unwrap_or(Value::Null);
    json!({
        "played": data.get("Played").and_then(|v| v.as_bool()).unwrap_or(false),
        "favorite": data.get("IsFavorite").and_then(|v| v.as_bool()).unwrap_or(false),
        "position": seconds(data.get("PlaybackPositionTicks")),
        "percent": number(&data, "PlayedPercentage"),
        "unplayed": number(&data, "UnplayedItemCount"),
        "lastPlayed": text(&data, "LastPlayedDate"),
    })
}

/// One item as a card: enough to draw it, open it and act on it.
pub fn card(item: &Value) -> Value {
    json!({
        "id": text(item, "Id"),
        "name": text(item, "Name"),
        "type": text(item, "Type"),
        "mediaType": text(item, "MediaType"),
        "collectionType": text(item, "CollectionType"),
        "isFolder": item.get("IsFolder").and_then(|v| v.as_bool()).unwrap_or(false),
        "year": number(item, "ProductionYear"),
        "endYear": item.get("EndDate").and_then(|v| v.as_str()).and_then(|d| d.get(..4)).and_then(|y| y.parse::<u32>().ok()),
        "status": text(item, "Status"),
        "premiere": text(item, "PremiereDate"),
        "runtime": seconds(item.get("RunTimeTicks")),
        "rating": number(item, "CommunityRating"),
        "officialRating": text(item, "OfficialRating"),
        "seriesId": text(item, "SeriesId"),
        "seriesName": text(item, "SeriesName"),
        "seasonId": text(item, "SeasonId"),
        "seasonName": text(item, "SeasonName"),
        "index": number(item, "IndexNumber"),
        "indexEnd": number(item, "IndexNumberEnd"),
        "parentIndex": number(item, "ParentIndexNumber"),
        "childCount": number(item, "ChildCount"),
        "aspect": number(item, "PrimaryImageAspectRatio"),
        "overview": text(item, "Overview"),
        "images": images(item),
        "user": user_data(item),
    })
}

fn cards(list: &Value) -> Vec<Value> {
    let items = list.get("Items").unwrap_or(list);
    items.as_array().map(|a| a.iter().map(card).collect()).unwrap_or_default()
}

fn total(list: &Value) -> u64 {
    list.get("TotalRecordCount").and_then(|v| v.as_u64()).unwrap_or(0)
}

/// A media stream as the pickers show it.
fn stream(s: &Value) -> Value {
    json!({
        "index": number(s, "Index"),
        "type": text(s, "Type"),
        "codec": text(s, "Codec"),
        "language": text(s, "Language"),
        "title": text(s, "Title"),
        "label": text(s, "DisplayTitle"),
        "isDefault": s.get("IsDefault").and_then(|v| v.as_bool()).unwrap_or(false),
        "isForced": s.get("IsForced").and_then(|v| v.as_bool()).unwrap_or(false),
        "isExternal": s.get("IsExternal").and_then(|v| v.as_bool()).unwrap_or(false),
        "isText": s.get("IsTextSubtitleStream").and_then(|v| v.as_bool()).unwrap_or(false),
        "channels": number(s, "Channels"),
        "width": number(s, "Width"),
        "height": number(s, "Height"),
        "range": text(s, "VideoRangeType"),
        "bitrate": number(s, "BitRate"),
    })
}

pub fn media_source(ms: &Value) -> Value {
    let streams: Vec<Value> = ms
        .get("MediaStreams")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter(|s| matches!(s["Type"].as_str(), Some("Video" | "Audio" | "Subtitle"))).map(stream).collect())
        .unwrap_or_default();
    json!({
        "id": text(ms, "Id"),
        "name": text(ms, "Name"),
        "container": text(ms, "Container"),
        "size": number(ms, "Size"),
        "bitrate": number(ms, "Bitrate"),
        "runtime": seconds(ms.get("RunTimeTicks")),
        "defaultAudio": number(ms, "DefaultAudioStreamIndex"),
        "defaultSubtitle": number(ms, "DefaultSubtitleStreamIndex"),
        "streams": streams,
    })
}

fn person(p: &Value) -> Value {
    json!({
        "id": text(p, "Id"),
        "name": text(p, "Name"),
        "role": text(p, "Role"),
        "type": text(p, "Type"),
        "image": image(p.get("Id").and_then(|v| v.as_str()), p.get("PrimaryImageTag").and_then(|v| v.as_str())),
    })
}

/// Trickplay (scrubbing thumbnails) for one media source: the widest set of
/// tiles that is not wider than 320 pixels, which reads well and loads fast.
pub fn trickplay(item: &Value, source_id: &str) -> Value {
    let Some(sets) = item.get("Trickplay").and_then(|t| t.get(source_id).or_else(|| t.as_object()?.values().next())) else {
        return Value::Null;
    };
    let Some(sets) = sets.as_object() else { return Value::Null };
    let mut best: Option<(u64, &Value)> = None;
    for (width, info) in sets {
        let Ok(w) = width.parse::<u64>() else { continue };
        let better = match best {
            None => true,
            Some((b, _)) => (w <= 320 && (b > 320 || w > b)) || (b > 320 && w < b),
        };
        if better {
            best = Some((w, info));
        }
    }
    let Some((width, info)) = best else { return Value::Null };
    json!({
        "width": width,
        "height": number(info, "Height"),
        "tileWidth": number(info, "TileWidth"),
        "tileHeight": number(info, "TileHeight"),
        "count": number(info, "ThumbnailCount"),
        "interval": number(info, "Interval"),
    })
}

// ---------------------------------------------------------------- server

pub async fn server_overview(app: &App) -> Result<Value> {
    let uid = user_id(app)?;
    let me = app.jellyfin.get("/Users/Me").await?;
    // Back online: what was watched offline goes to the server.
    crate::downloads::sync_pending(app).await;
    let (base, _) = app.jellyfin.base().await?;
    let info = app.jellyfin.public_info(&base).await.unwrap_or(Value::Null);
    let views = views_list_for(app, &uid).await.unwrap_or_default();
    let route = app.jellyfin.route().await;
    Ok(json!({
        "user": {
            "id": text(&me, "Id"),
            "name": text(&me, "Name"),
            "isAdmin": me.pointer("/Policy/IsAdministrator").and_then(|v| v.as_bool()).unwrap_or(false),
            "image": image(me.get("Id").and_then(|v| v.as_str()), me.get("PrimaryImageTag").and_then(|v| v.as_str())),
        },
        "server": { "name": text(&info, "ServerName"), "version": text(&info, "Version"), "id": text(&info, "Id") },
        "views": views,
        "route": route,
    }))
}

async fn views_list_for(app: &App, uid: &str) -> Result<Vec<Value>> {
    let list = app.jellyfin.get(&format!("/UserViews?userId={uid}&includeExternalContent=false")).await?;
    Ok(cards(&list))
}

pub async fn views_list(app: &App) -> Result<Value> {
    let uid = user_id(app)?;
    Ok(json!(views_list_for(app, &uid).await?))
}

// ---------------------------------------------------------------- home

/// The home page in one call: what you are watching, what comes next, and
/// what is new in each library. A row that fails is left out rather than
/// failing the page.
pub async fn home(app: &App) -> Result<Value> {
    let uid = user_id(app)?;
    let jf = &app.jellyfin;
    let resume_path = format!(
        "/UserItems/Resume?userId={uid}&limit=24&mediaTypes=Video&fields={CARD_FIELDS},Overview&{CARD_IMAGES}&enableTotalRecordCount=false"
    );
    let next_path = format!(
        "/Shows/NextUp?userId={uid}&limit=24&fields={CARD_FIELDS},Overview&{CARD_IMAGES}&enableResumable=false&enableRewatching=false&enableTotalRecordCount=false"
    );
    let (resume, next_up, views) = tokio::join!(jf.get(&resume_path), jf.get(&next_path), views_list_for(app, &uid));
    let views = views?;
    let mut latest_rows = Vec::new();
    let latest = futures_util::future::join_all(
        views
            .iter()
            .filter(|v| matches!(v["collectionType"].as_str(), Some("movies" | "tvshows" | "homevideos" | "musicvideos") | None))
            .filter(|v| v["id"].as_str().map(valid_id).unwrap_or(false))
            .map(|v| {
                let id = v["id"].as_str().unwrap_or_default().to_string();
                let name = v["name"].clone();
                let kind = v["collectionType"].clone();
                let path = format!(
                    "/Items/Latest?userId={uid}&parentId={id}&limit=24&fields={CARD_FIELDS}&{CARD_IMAGES}&groupItems=true"
                );
                async move { (id, name, kind, jf.get(&path).await) }
            }),
    )
    .await;
    for (id, name, kind, result) in latest {
        if let Ok(list) = result {
            let items = cards(&list);
            if !items.is_empty() {
                latest_rows.push(json!({ "viewId": id, "title": name, "collectionType": kind, "items": items }));
            }
        }
    }
    let mut errors = Vec::new();
    let resume = resume.map(|l| cards(&l)).unwrap_or_else(|e| { errors.push(e.message); Vec::new() });
    let next_up = next_up.map(|l| cards(&l)).unwrap_or_else(|e| { errors.push(e.message); Vec::new() });
    Ok(json!({ "resume": resume, "nextUp": next_up, "latest": latest_rows, "views": views, "errors": errors }))
}

// ---------------------------------------------------------------- lists

const SORTS: [(&str, &str); 8] = [
    ("name", "SortName"),
    ("added", "DateCreated,SortName"),
    ("released", "PremiereDate,ProductionYear,SortName"),
    ("rating", "CommunityRating,SortName"),
    ("critics", "CriticRating,SortName"),
    ("runtime", "Runtime,SortName"),
    ("played", "DatePlayed,SortName"),
    ("random", "Random"),
];

/// A page of a library, a collection, favourites or a search, with sorting
/// and filters. Only known sort keys, filters and item types pass through.
pub async fn items_list(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let mut query = vec![
        format!("userId={uid}"),
        format!("fields={CARD_FIELDS}"),
        CARD_IMAGES.to_string(),
        "enableTotalRecordCount=true".into(),
    ];
    let parent = str_param(params, "parentId");
    if !parent.is_empty() {
        query.push(format!("parentId={}", require_id(parent)?));
    }
    let person = str_param(params, "personId");
    if !person.is_empty() {
        query.push(format!("personIds={}", require_id(person)?));
    }
    let types = str_param(params, "types");
    let allowed_types = ["Movie", "Series", "Episode", "Season", "BoxSet", "Video", "MusicVideo", "Folder", "CollectionFolder", "Playlist", "Person"];
    let types: Vec<&str> = types.split(',').map(str::trim).filter(|t| !t.is_empty()).collect();
    if types.iter().any(|t| !allowed_types.contains(t)) {
        return Err(Error::invalid("Unknown item type"));
    }
    if !types.is_empty() {
        query.push(format!("includeItemTypes={}", types.join(",")));
    }
    if bool_param(params, "recursive").unwrap_or(!types.is_empty()) {
        query.push("recursive=true".into());
    }
    let sort = str_param(params, "sort");
    let sort_by = match sort {
        "" => None,
        key => Some(SORTS.iter().find(|(k, _)| *k == key).map(|(_, v)| *v).ok_or_else(|| Error::invalid("Unknown sort"))?),
    };
    if let Some(sort_by) = sort_by {
        query.push(format!("sortBy={sort_by}"));
        let descending = bool_param(params, "descending").unwrap_or(false);
        query.push(format!("sortOrder={}", if descending { "Descending" } else { "Ascending" }));
    }
    let mut filters = Vec::new();
    for filter in params.get("filters").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
        filters.push(match filter.as_str().unwrap_or("") {
            "played" => "IsPlayed",
            "unplayed" => "IsUnplayed",
            "favorite" => "IsFavorite",
            "resumable" => "IsResumable",
            _ => return Err(Error::invalid("Unknown filter")),
        });
    }
    if !filters.is_empty() {
        query.push(format!("filters={}", filters.join(",")));
    }
    let genres: Vec<String> = params
        .get("genres")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|g| g.as_str()).filter(|g| !g.is_empty() && g.len() < 120).map(q).collect())
        .unwrap_or_default();
    if !genres.is_empty() {
        // Jellyfin separates genres with a pipe, because names may hold commas.
        query.push(format!("genres={}", genres.join("%7C")));
    }
    let years: Vec<String> = params
        .get("years")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|y| y.as_u64()).filter(|y| (1800..3000).contains(y)).map(|y| y.to_string()).collect())
        .unwrap_or_default();
    if !years.is_empty() {
        query.push(format!("years={}", years.join(",")));
    }
    let term = str_param(params, "search").trim();
    if !term.is_empty() {
        query.push(format!("searchTerm={}", q(&term.chars().take(200).collect::<String>())));
    }
    let letter = str_param(params, "startsWith");
    if letter.len() == 1 && letter.chars().all(|c| c.is_ascii_alphabetic()) {
        query.push(format!("nameStartsWith={letter}"));
    } else if letter == "#" {
        query.push("nameLessThan=A".into());
    }
    query.push(format!("startIndex={}", u64_param(params, "start").unwrap_or(0)));
    query.push(format!("limit={}", u64_param(params, "limit").unwrap_or(100).clamp(1, 500)));
    let list = app.jellyfin.get(&format!("/Items?{}", query.join("&"))).await?;
    Ok(json!({ "items": cards(&list), "total": total(&list) }))
}

pub async fn genres_list(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let mut path = format!("/Genres?userId={uid}&sortBy=SortName&enableImages=false&enableTotalRecordCount=false");
    let parent = str_param(params, "parentId");
    if !parent.is_empty() {
        path.push_str(&format!("&parentId={}", require_id(parent)?));
    }
    let list = app.jellyfin.get(&path).await?;
    let names: Vec<Value> = list
        .get("Items")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|g| g.get("Name").cloned()).collect())
        .unwrap_or_default();
    Ok(json!(names))
}

// ---------------------------------------------------------------- one item

/// A details page: the card, plus the story, the people, the files and,
/// for a show, the episode to watch next.
/// The offline stand-in for a failed request: when the server cannot be
/// reached, a downloaded title answers from its saved metadata.
fn offline(err: &Error) -> bool {
    err.code == crate::error::NETWORK || err.code == crate::error::NOT_CONFIGURED
}

pub async fn item_get(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let uid = match user_id(app) {
        Ok(uid) => uid,
        Err(err) => return crate::downloads::offline_details(app, id).ok_or(err),
    };
    let item = match app.jellyfin.get(&format!("/Items/{id}?userId={uid}")).await {
        Ok(item) => item,
        Err(err) if offline(&err) => return crate::downloads::offline_details(app, id).ok_or(err),
        Err(err) => return Err(err),
    };
    let mut out = details(&item, id);
    if item["Type"] == "Series" {
        let next = app
            .jellyfin
            .get(&format!("/Shows/NextUp?userId={uid}&seriesId={id}&limit=1&fields={CARD_FIELDS},Overview&{CARD_IMAGES}&enableResumable=true&enableRewatching=false"))
            .await
            .ok()
            .and_then(|l| cards(&l).into_iter().next());
        out["nextUp"] = next.unwrap_or(Value::Null);
    }
    Ok(out)
}

/// A details page from a full item, as the server sends it or as a
/// download saved it.
pub fn details(item: &Value, id: &str) -> Value {
    let mut out = card(&item);
    let obj = out.as_object_mut().expect("card is an object");
    obj.insert("overview".into(), text(&item, "Overview"));
    obj.insert("tagline".into(), item.get("Taglines").and_then(|t| t.as_array()).and_then(|a| a.first()).cloned().unwrap_or(Value::Null));
    obj.insert("genres".into(), item.get("Genres").cloned().unwrap_or(json!([])));
    obj.insert("studios".into(), json!(item.get("Studios").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|s| s.get("Name").cloned()).collect::<Vec<_>>()).unwrap_or_default()));
    obj.insert("criticRating".into(), number(&item, "CriticRating"));
    obj.insert("endDate".into(), text(&item, "EndDate"));
    obj.insert("dateAdded".into(), text(&item, "DateCreated"));
    obj.insert("path".into(), text(&item, "Path"));
    let people: Vec<Value> = item.get("People").and_then(|v| v.as_array()).map(|a| a.iter().take(40).map(person).collect()).unwrap_or_default();
    obj.insert("people".into(), json!(people));
    let sources: Vec<Value> = item.get("MediaSources").and_then(|v| v.as_array()).map(|a| a.iter().map(media_source).collect()).unwrap_or_default();
    let first_source = sources.first().and_then(|s| s["id"].as_str()).unwrap_or(id).to_string();
    obj.insert("sources".into(), json!(sources));
    let chapters: Vec<Value> = item
        .get("Chapters")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().map(|c| json!({ "name": text(c, "Name"), "start": seconds(c.get("StartPositionTicks")).as_f64().unwrap_or(0.0) })).collect())
        .unwrap_or_default();
    obj.insert("chapters".into(), json!(chapters));
    obj.insert("trickplay".into(), trickplay(&item, &first_source));
    let trailers: Vec<Value> = item
        .get("RemoteTrailers")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|t| t.get("Url").and_then(|u| u.as_str())).filter(|u| u.starts_with("https://")).map(|u| json!(u)).collect())
        .unwrap_or_default();
    obj.insert("trailers".into(), json!(trailers));
    obj.insert("localTrailers".into(), number(&item, "LocalTrailerCount"));
    let mut links = Map::new();
    if let Some(ids) = item.get("ProviderIds").and_then(|v| v.as_object()) {
        for (key, value) in ids {
            let Some(v) = value.as_str() else { continue };
            if !v.chars().all(|c| c.is_ascii_alphanumeric()) {
                continue;
            }
            let url = match (key.as_str(), item["Type"].as_str()) {
                ("Imdb", _) => format!("https://www.imdb.com/title/{v}/"),
                ("Tmdb", Some("Series")) => format!("https://www.themoviedb.org/tv/{v}"),
                ("Tmdb", Some("Movie")) => format!("https://www.themoviedb.org/movie/{v}"),
                _ => continue,
            };
            links.insert(key.clone(), json!(url));
        }
    }
    obj.insert("links".into(), Value::Object(links));
    out
}

pub async fn seasons(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let uid = match user_id(app) {
        Ok(uid) => uid,
        Err(_) => return Ok(json!(crate::downloads::offline_seasons(app, id))),
    };
    match app.jellyfin.get(&format!("/Shows/{id}/Seasons?userId={uid}&fields={CARD_FIELDS}&{CARD_IMAGES}")).await {
        Ok(list) => Ok(json!(cards(&list))),
        Err(err) if offline(&err) => Ok(json!(crate::downloads::offline_seasons(app, id))),
        Err(err) => Err(err),
    }
}

pub async fn episodes(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let season = str_param(params, "seasonId");
    if !season.is_empty() {
        require_id(season)?;
    }
    let uid = match user_id(app) {
        Ok(uid) => uid,
        Err(_) => return Ok(json!(crate::downloads::offline_episodes(app, id, season))),
    };
    let mut path = format!("/Shows/{id}/Episodes?userId={uid}&fields={CARD_FIELDS},Overview&{CARD_IMAGES}");
    if !season.is_empty() {
        path.push_str(&format!("&seasonId={season}"));
    }
    match app.jellyfin.get(&path).await {
        Ok(list) => Ok(json!(cards(&list))),
        Err(err) if offline(&err) => Ok(json!(crate::downloads::offline_episodes(app, id, season))),
        Err(err) => Err(err),
    }
}

/// The episode after this one, across seasons, or null at the end of a show.
pub async fn next_episode(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let series = id_param(params, "seriesId")?;
    let uid = match user_id(app) {
        Ok(uid) => uid,
        Err(_) => return Ok(crate::downloads::offline_next(app, id, series)),
    };
    let list = match app
        .jellyfin
        .get(&format!("/Shows/{series}/Episodes?userId={uid}&startItemId={id}&limit=2&fields={CARD_FIELDS},Overview&{CARD_IMAGES}"))
        .await
    {
        Ok(list) => list,
        Err(err) if offline(&err) => return Ok(crate::downloads::offline_next(app, id, series)),
        Err(err) => return Err(err),
    };
    let items = cards(&list);
    Ok(items.into_iter().find(|e| e["id"].as_str() != Some(id)).unwrap_or(Value::Null))
}

pub async fn similar(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let id = id_param(params, "id")?;
    match app.jellyfin.get(&format!("/Items/{id}/Similar?userId={uid}&limit=16&fields={CARD_FIELDS}&{CARD_IMAGES}")).await {
        Ok(list) => Ok(json!(cards(&list))),
        Err(err) if offline(&err) => Ok(json!([])),
        Err(err) => Err(err),
    }
}

// ---------------------------------------------------------------- search

/// Movies, shows, episodes and people that match, each its own row.
pub async fn search(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let term: String = str_param(params, "term").trim().chars().take(200).collect();
    if term.is_empty() {
        return Ok(json!({ "movies": [], "series": [], "episodes": [], "people": [], "collections": [] }));
    }
    let t = q(&term);
    let base = format!("/Items?userId={uid}&searchTerm={t}&recursive=true&limit=40&fields={CARD_FIELDS}&{CARD_IMAGES}&enableTotalRecordCount=false");
    let jf = &app.jellyfin;
    let paths = [
        format!("{base}&includeItemTypes=Movie"),
        format!("{base}&includeItemTypes=Series"),
        format!("{base}&includeItemTypes=Episode"),
        format!("{base}&includeItemTypes=BoxSet"),
        format!("/Persons?userId={uid}&searchTerm={t}&limit=24&enableImages=true&enableTotalRecordCount=false"),
    ];
    let (movies, series, episodes, collections, people) =
        tokio::join!(jf.get(&paths[0]), jf.get(&paths[1]), jf.get(&paths[2]), jf.get(&paths[3]), jf.get(&paths[4]));
    let movies = movies?;
    Ok(json!({
        "movies": cards(&movies),
        "series": series.map(|l| cards(&l)).unwrap_or_default(),
        "episodes": episodes.map(|l| cards(&l)).unwrap_or_default(),
        "collections": collections.map(|l| cards(&l)).unwrap_or_default(),
        "people": people.map(|l| cards(&l)).unwrap_or_default(),
    }))
}

// ---------------------------------------------------------------- marks

pub async fn set_played(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let id = id_param(params, "id")?;
    let played = bool_param(params, "played").ok_or_else(|| Error::invalid("Say whether it was played"))?;
    let path = format!("/UserPlayedItems/{id}?userId={uid}");
    let mut data = if played { app.jellyfin.post(&path, Value::Null).await? } else { app.jellyfin.delete(&path).await? };
    // Marking watched forgets where you were; undoing it puts that back.
    if let Some(position) = params.get("restorePosition").and_then(|v| v.as_f64()).filter(|p| *p > 0.0 && !played) {
        let ticks = (position * TICKS_PER_SECOND as f64) as i64;
        data = app
            .jellyfin
            .post(&format!("/UserItems/{id}/UserData?userId={uid}"), json!({ "PlaybackPositionTicks": ticks }))
            .await?;
    }
    Ok(user_data(&json!({ "UserData": data })))
}

pub async fn set_favorite(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let id = id_param(params, "id")?;
    let favorite = bool_param(params, "favorite").ok_or_else(|| Error::invalid("Say whether it is a favourite"))?;
    let path = format!("/UserFavoriteItems/{id}?userId={uid}");
    let data = if favorite { app.jellyfin.post(&path, Value::Null).await? } else { app.jellyfin.delete(&path).await? };
    Ok(user_data(&json!({ "UserData": data })))
}

/// Forget where you stopped, so it leaves Continue watching.
pub async fn clear_resume(app: &App, params: &Value) -> Result<Value> {
    let uid = user_id(app)?;
    let id = id_param(params, "id")?;
    let data = app
        .jellyfin
        .post(&format!("/UserItems/{id}/UserData?userId={uid}"), json!({ "PlaybackPositionTicks": 0 }))
        .await?;
    Ok(user_data(&json!({ "UserData": data })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn episodes_borrow_the_shows_pictures() {
        let episode = json!({
            "Id": "28046ebec64754019cdf75cd027cb6ab", "Type": "Episode", "Name": "Pilot",
            "ImageTags": { "Primary": "p1" },
            "ParentBackdropItemId": "bd752a7f5658897bcfdbccf0c1bc9e53", "ParentBackdropImageTags": ["b1"],
            "ParentLogoItemId": "bd752a7f5658897bcfdbccf0c1bc9e53", "ParentLogoImageTag": "l1",
            "SeriesId": "bd752a7f5658897bcfdbccf0c1bc9e53", "SeriesPrimaryImageTag": "s1",
            "RunTimeTicks": 32820266670i64,
            "UserData": { "Played": false, "PlaybackPositionTicks": 600000000, "IsFavorite": true }
        });
        let c = card(&episode);
        assert_eq!(c["images"]["primary"]["tag"], "p1");
        assert_eq!(c["images"]["backdrop"]["id"], "bd752a7f5658897bcfdbccf0c1bc9e53");
        assert_eq!(c["images"]["logo"]["tag"], "l1");
        assert_eq!(c["images"]["thumb"], Value::Null);
        assert_eq!(c["runtime"], 3282.0);
        assert_eq!(c["user"]["position"], 60.0);
        assert_eq!(c["user"]["favorite"], true);
    }

    #[test]
    fn picks_a_trickplay_width_near_320() {
        let item = json!({ "Trickplay": { "abc": {
            "320": { "Height": 180, "TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 500, "Interval": 10000 },
            "640": { "Height": 360 }, "160": { "Height": 90 } } } });
        assert_eq!(trickplay(&item, "abc")["width"], 320);
        let item = json!({ "Trickplay": { "abc": { "640": {}, "480": {} } } });
        assert_eq!(trickplay(&item, "abc")["width"], 480);
        assert_eq!(trickplay(&json!({ "Trickplay": {} }), "abc"), Value::Null);
    }

    #[test]
    fn drops_invalid_image_owners() {
        assert_eq!(image(Some("../x"), Some("t")), Value::Null);
        assert_eq!(image(Some("bd752a7f5658897bcfdbccf0c1bc9e53"), Some("")), Value::Null);
    }
}
