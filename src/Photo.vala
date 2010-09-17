/* Copyright 2009-2010 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

public enum ImportResult {
    SUCCESS,
    FILE_ERROR,
    DECODE_ERROR,
    DATABASE_ERROR,
    USER_ABORT,
    NOT_A_FILE,
    PHOTO_EXISTS,
    UNSUPPORTED_FORMAT,
    NOT_AN_IMAGE,
    DISK_FAILURE,
    DISK_FULL,
    CAMERA_ERROR;
    
    public string to_string() {
        switch (this) {
            case SUCCESS:
                return _("Success");
            
            case FILE_ERROR:
                return _("File error");
            
            case DECODE_ERROR:
                return _("Unable to decode file");
            
            case DATABASE_ERROR:
                return _("Database error");
            
            case USER_ABORT:
                return _("User aborted import");
            
            case NOT_A_FILE:
                return _("Not a file");
            
            case PHOTO_EXISTS:
                return _("File already exists in database");
            
            case UNSUPPORTED_FORMAT:
                return _("Unsupported file format");

            case NOT_AN_IMAGE:
                return _("Not an image file");
            
            case DISK_FAILURE:
                return _("Disk failure");
            
            case DISK_FULL:
                return _("Disk full");
            
            case CAMERA_ERROR:
                return _("Camera error");
            
            default:
                return _("Imported failed (%d)").printf((int) this);
        }
    }
    
    public bool is_abort() {
        switch (this) {
            case ImportResult.DISK_FULL:
            case ImportResult.DISK_FAILURE:
            case ImportResult.USER_ABORT:
                return true;
            
            default:
                return false;
        }
    }
    
    public bool is_nonuser_abort() {
        switch (this) {
            case ImportResult.DISK_FULL:
            case ImportResult.DISK_FAILURE:
                return true;
            
            default:
                return false;
        }
    }
    
    public static ImportResult convert_error(Error err, ImportResult default_result) {
        if (err is FileError) {
            FileError ferr = (FileError) err;
            
            if (ferr is FileError.NOSPC)
                return ImportResult.DISK_FULL;
            else if (ferr is FileError.IO)
                return ImportResult.DISK_FAILURE;
            else if (ferr is FileError.ISDIR)
                return ImportResult.NOT_A_FILE;
            else
                return ImportResult.FILE_ERROR;
        } else if (err is IOError) {
            IOError ioerr = (IOError) err;
            
            if (ioerr is IOError.NO_SPACE)
                return ImportResult.DISK_FULL;
            else if (ioerr is IOError.FAILED)
                return ImportResult.DISK_FAILURE;
            else if (ioerr is IOError.IS_DIRECTORY)
                return ImportResult.NOT_A_FILE;
            else if (ioerr is IOError.CANCELLED)
                return ImportResult.USER_ABORT;
            else
                return ImportResult.FILE_ERROR;
        } else if (err is GPhotoError) {
            return ImportResult.CAMERA_ERROR;
        }
        
        return default_result;
    }
}

// Specifies how pixel data is fetched from the backing file on disk.  MASTER is the original
// backing photo of any supported photo file format; SOURCE is either the master or the editable
// file, that is, the appropriate reference file for user display; BASELINE is an appropriate source
// file with the proviso that it may be a suitable substitute for the master and/or the editable.
//
// In general, callers want to use the BASELINE unless requirements are specific.
public enum BackingFetchMode {
    SOURCE,
    BASELINE,
    MASTER
}

public class PhotoImportParams {
    // IN:
    public File file;
    public ImportID import_id;
    public PhotoFileSniffer.Options sniffer_options;
    public string? exif_md5;
    public string? thumbnail_md5;
    public string? full_md5;
    
    // IN/OUT:
    public Thumbnails? thumbnails;
    
    // OUT:
    public PhotoRow row = PhotoRow();
    public Gee.Collection<string>? keywords = null;
    
    public PhotoImportParams(File file, ImportID import_id, PhotoFileSniffer.Options sniffer_options,
        string? exif_md5, string? thumbnail_md5, string? full_md5, Thumbnails? thumbnails = null) {
        this.file = file;
        this.import_id = import_id;
        this.sniffer_options = sniffer_options;
        this.exif_md5 = exif_md5;
        this.thumbnail_md5 = thumbnail_md5;
        this.full_md5 = full_md5;
        this.thumbnails = thumbnails;
    }
}

public abstract class PhotoTransformationState : Object {
    private bool is_broke = false;
    
    // This signal is fired when the Photo object can no longer accept it and reliably return to
    // this state.
    public virtual signal void broken() {
        is_broke = true;
    }
    
    protected PhotoTransformationState() {
    }
    
    public bool is_broken() {
        return is_broke;
    }
}

public enum Rating {
    REJECTED = -1,
    UNRATED = 0,
    ONE = 1,
    TWO = 2,
    THREE = 3,
    FOUR = 4,
    FIVE = 5;

    public bool can_increase() {
        return this < FIVE;
    }

    public bool can_decrease() {
	    return this > REJECTED;
    }

    public bool is_valid() {
        return this >= REJECTED && this <= FIVE;
    }

    public Rating increase() {
        return can_increase() ? this + 1 : this;
    }

    public Rating decrease() {
        return can_decrease() ? this - 1 : this;
    }
    
    public int serialize() {
        switch (this) {
            case REJECTED:
                return -1;
            case UNRATED:
                return 0;
            case ONE:
                return 1;
            case TWO:
                return 2;
            case THREE:
                return 3;
            case FOUR:
                return 4;
            case FIVE:
                return 5;
            default:
                return 0;
        }
    }

    public static Rating unserialize(int value) {
        if (value > FIVE)
            return FIVE;
        else if (value < REJECTED)
            return REJECTED;
        
        switch (value) {
            case -1:
                return REJECTED;
            case 0:
                return UNRATED;
            case 1:
                return ONE;
            case 2:
                return TWO;
            case 3:
                return THREE;
            case 4:
                return FOUR;
            case 5:
                return FIVE;
            default:
                return UNRATED;
        }
    }
}

// Photo is an abstract class that allows for applying transformations on-the-fly to a
// particular photo without modifying the backing image file.  The interface allows for
// transformations to be stored persistently elsewhere or in memory until they're commited en
// masse to an image file.
public abstract class Photo : PhotoSource {
    private const string[] IMAGE_EXTENSIONS = {
        // raster formats
        "jpg", "jpeg", "jpe",
        "tiff", "tif",
        "png",
        "gif",
        "bmp",
        "ppm", "pgm", "pbm", "pnm",
        
        // THM are JPEG thumbnails produced by some RAW cameras ... want to support the RAW
        // image but not import their thumbnails
        "thm",
        
        // less common
        "tga", "ilbm", "pcx", "ecw", "img", "sid", "cd5", "fits", "pgf",
        
        // vector
        "cgm", "svg", "odg", "eps", "pdf", "swf", "wmf", "emf", "xps",
        
        // 3D
        "pns", "jps", "mpo",
        
        // RAW extensions
        "3fr", "arw", "srf", "sr2", "bay", "crw", "cr2", "cap", "iiq", "eip", "dcs", "dcr", "drf",
        "k25", "kdc", "dng", "erf", "fff", "mef", "mos", "mrw", "nef", "nrw", "orf", "ptx", "pef",
        "pxn", "r3d", "raf", "raw", "rw2", "rwl", "rwz", "x3f"
    };
    
    // There are assertions in the photo pipeline to verify that the generated (or loaded) pixbuf
    // is scaled properly.  We have to allow for some wobble here because of rounding errors and
    // precision limitations of various subsystems.  Pixel-accuracy would be best, but barring that,
    // need to just make sure the pixbuf is in the ballpark.
    private const int SCALING_FUDGE = 8;
    
    public enum Exception {
        NONE            = 0,
        ORIENTATION     = 1 << 0,
        CROP            = 1 << 1,
        REDEYE          = 1 << 2,
        ADJUST          = 1 << 3,
        ALL             = 0xFFFFFFFF;
        
        public bool prohibits(Exception exception) {
            return ((this & exception) != 0);
        }
        
        public bool allows(Exception exception) {
            return ((this & exception) == 0);
        }
    }
    
    // NOTE: This class should only be instantiated when row is locked.
    private class PhotoTransformationStateImpl : PhotoTransformationState {
        private Photo photo;
        private Orientation orientation;
        private Gee.HashMap<string, KeyValueMap>? transformations;
        private PixelTransformer? transformer;
        private PixelTransformationBundle? adjustments;
        
        public PhotoTransformationStateImpl(Photo photo, Orientation orientation,
            Gee.HashMap<string, KeyValueMap>? transformations, PixelTransformer? transformer,
            PixelTransformationBundle? adjustments) {
            this.photo = photo;
            this.orientation = orientation;
            this.transformations = copy_transformations(transformations);
            this.transformer = transformer;
            this.adjustments = adjustments;
            
            photo.baseline_replaced.connect(on_photo_baseline_replaced);
        }
        
        ~PhotoTransformationStateImpl() {
            photo.baseline_replaced.disconnect(on_photo_baseline_replaced);
        }
        
        public Orientation get_orientation() {
            return orientation;
        }
        
        public Gee.HashMap<string, KeyValueMap>? get_transformations() {
            return copy_transformations(transformations);
        }
        
        public PixelTransformer? get_transformer() {
            return (transformer != null) ? transformer.copy() : null;
        }
        
        public PixelTransformationBundle? get_color_adjustments() {
            return (adjustments != null) ? adjustments.copy() : null;
        }
        
        private static Gee.HashMap<string, KeyValueMap>? copy_transformations(
            Gee.HashMap<string, KeyValueMap>? original) {
            if (original == null)
                return null;
            
            Gee.HashMap<string, KeyValueMap>? clone = new Gee.HashMap<string, KeyValueMap>();
            foreach (string object in original.keys)
                clone.set(object, original.get(object).copy());
            
            return clone;
        }
        
        private void on_photo_baseline_replaced() {
            if (!is_broken())
                broken();
        }
    }
    
    private struct BackingReaders {
        public PhotoFileReader master;
        public PhotoFileReader mimic;
        public PhotoFileReader editable;
    }
    
    // because fetching individual items from the database is high-overhead, store all of
    // the photo row in memory
    private PhotoRow row;
    private BackingPhotoState editable = BackingPhotoState();
    private BackingReaders readers = BackingReaders();
    private PixelTransformer transformer = null;
    private PixelTransformationBundle adjustments = null;
    // because file_title is determined by data in row, it should only be accessed when row is locked
    private string file_title = null;
    private FileMonitor editable_monitor = null;
    private OneShotScheduler reimport_editable_scheduler = null;
    private OneShotScheduler update_editable_attributes_scheduler = null;
    private OneShotScheduler remove_editable_scheduler = null;
    
    // This pointer is used to determine which BackingPhotoState in the PhotoRow to be using at
    // any time.  It should only be accessed -- read or write -- when row is locked.
    private BackingPhotoState *backing_photo_state = null;
    
    // This is fired when the photo's master file is replaced.  The image it generates may or may
    // not be the same; the altered signal is the best determinant for that.
    public virtual signal void master_replaced(File old_file, File new_file) {
    }
    
    // This is fired when the photo's editable file is replaced.  The image it generates may or
    // may not be the same; the altered signal is best for that.  null is passed if the editable
    // is being added, replaced, or removed (in the appropriate places)
    public virtual signal void editable_replaced(File? old_file, File? new_file) {
    }
    
    // This is fired when the photo's baseline file (the file that generates images at the head
    // of the pipeline) is replaced.  Photo will make every sane effort to only fire this signal
    // if the new baseline is the same image-wise (i.e. the pixbufs it generates are essentially
    // the same).
    public virtual signal void baseline_replaced() {
    }
    
    // The key to this implementation is that multiple instances of Photo with the
    // same PhotoID cannot exist; it is up to the subclasses to ensure this.
    protected Photo(PhotoRow row) {
        this.row = row;
        
        // don't need to lock the struct in the constructor (and to do so would hurt startup
        // time)
        readers.master = row.master.file_format.create_reader(row.master.filepath);
        
        // get the file title of the Photo without using a File object, skipping the separator itself
        char *basename = row.master.filepath.rchr(-1, Path.DIR_SEPARATOR);
        if (basename != null)
            file_title = (string) (basename + 1);
        
        if (is_string_empty(file_title))
            file_title = row.master.filepath;
        
        if (row.editable_id.id != BackingPhotoID.INVALID) {
            BackingPhotoRow? editable_row = null;
            try {
                editable_row = BackingPhotoTable.get_instance().fetch(row.editable_id);
            } catch (DatabaseError err) {
                warning("Unable to fetch editable state for %s: %s", to_string(), err.message);
            }
            
            if (editable_row != null) {
                editable = editable_row.state;
                readers.editable = editable.file_format.create_reader(editable.filepath);
            } else {
                try {
                    BackingPhotoTable.get_instance().remove(row.editable_id);
                } catch (DatabaseError err) {
                    // ignored
                }
                
                try {
                    PhotoTable.get_instance().detach_editable(ref this.row);
                } catch (DatabaseError err) {
                    // ignored
                }
                
                // need to remove all transformations as they're keyed to the editable's
                // coordinate system
                internal_remove_all_transformations(false);
            }
        }
        
        // set the backing photo state appropriately
        backing_photo_state = (readers.editable == null) ? &this.row.master : &this.editable;
    }
    
    protected virtual void notify_master_replaced(File old_file, File new_file) {
        master_replaced(old_file, new_file);
    }
    
    protected virtual void notify_editable_replaced(File? old_file, File? new_file) {
        editable_replaced(old_file, new_file);
    }
    
    protected virtual void notify_baseline_replaced() {
        baseline_replaced();
    }
    
    public override bool internal_delete_backing() throws Error {
        File file = null;
        lock (readers) {
            if (readers.editable != null)
                file = readers.editable.get_file();
        }
        
        detach_editable(true, false);
        
        if (file != null) {
            try {
                file.trash(null);
            } catch (Error err) {
                message("Unable to move editable %s for %s to trash: %s", file.get_path(), to_string(),
                    err.message);
            }
        }
        
        return base.internal_delete_backing();
    }
    
    // For the MimicManager
    public bool would_use_mimic() {
        PhotoFileFormatFlags flags;
        lock (readers) {
            flags = readers.master.get_file_format().get_properties().get_flags();
        }
        
        return (flags & PhotoFileFormatFlags.MIMIC_RECOMMENDED) != 0;
    }
    
    private PhotoFileReader get_backing_reader(BackingFetchMode mode) {
        switch (mode) {
            case BackingFetchMode.MASTER:
                return get_master_reader();
            
            case BackingFetchMode.BASELINE:
                return get_baseline_reader();
            
            case BackingFetchMode.SOURCE:
                return get_source_reader();
            
            default:
                error("Unknown backing fetch mode %s", mode.to_string());
        }
    }
    
    private PhotoFileReader get_master_reader() {
        lock (readers) {
            return readers.master;
        }
    }
    
    // For the MimicManager
    public void set_mimic_reader(PhotoFileReader mimic) {
        if (no_mimicked_images)
            return;
        
        // Do *not* fire baseline_replaced, because the mimic produces images subjectively the same
        // as the master.
        lock (readers) {
            readers.mimic = mimic;
        }
    }
    
    protected PhotoFileReader? get_editable_reader() {
        lock (readers) {
            return readers.editable;
        }
    }
    
    // Returns a reader for the head of the pipeline, which can be a mimic.
    private PhotoFileReader get_baseline_reader() {
        lock (readers) {
            if (readers.editable != null)
                return readers.editable;
            
            if (readers.mimic != null)
                return readers.mimic;
            
            return readers.master;
        }
    }
    
    // Returns a reader for the photo file that is the source of the image (which the mimic
    // is not).
    private PhotoFileReader get_source_reader() {
        lock (readers) {
            return readers.editable ?? readers.master;
        }
    }
    
    public bool is_mimicked() {
        lock (readers) {
            return readers.mimic != null;
        }
    }
    
    public bool has_editable() {
        lock (readers) {
            return readers.editable != null;
        }
    }
    
    public bool does_master_exist() {
        lock (readers) {
            return readers.master.file_exists();
        }
    }
    
    // Returns false if the backing editable does not exist OR the photo does not have an editable
    public bool does_editable_exist() {
        lock (readers) {
            return readers.editable != null ? readers.editable.file_exists() : false;
        }
    }
    
    public bool is_master_baseline() {
        lock (readers) {
            return readers.mimic == null && readers.editable == null;
        }
    }
    
    public bool is_editable_baseline() {
        lock (readers) {
            return readers.mimic == null && readers.editable != null;
        }
    }
    
    public BackingPhotoState get_master_photo_state() {
        lock (row) {
            return row.master;
        }
    }
    
    public BackingPhotoState? get_editable_photo_state() {
        lock (row) {
            // ternary doesn't work here
            if (row.editable_id.is_valid())
                return editable;
            else
                return null;
        }
    }
    
    // This method interrogates the specified file and returns a PhotoRow with all relevant
    // information about it.  It uses the PhotoFileInterrogator to do so.  The caller should create
    // a PhotoFileInterrogator with the proper options prior to calling.  prepare_for_import()
    // will determine what's been discovered and fill out in the PhotoRow or return the relevant
    // objects and information.  If Thumbnails is not null, thumbnails suitable for caching or
    // framing will be returned as well.  Note that this method will call interrogate() and
    // perform all error-handling; the caller simply needs to construct the object.
    //
    // This is the acid-test; if unable to generate a pixbuf or thumbnails, that indicates the 
    // photo itself is bogus and should be discarded.
    //
    // NOTE: This method is thread-safe.
    public static ImportResult prepare_for_import(PhotoImportParams params) {
#if MEASURE_IMPORT
        Timer total_time = new Timer();
#endif
        File file = params.file;
        
        FileInfo info = null;
        try {
            info = file.query_info(DirectoryMonitor.SUPPLIED_ATTRIBUTES,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        } catch (Error err) {
            return ImportResult.FILE_ERROR;
        }
        
        if (info.get_file_type() != FileType.REGULAR)
            return ImportResult.NOT_A_FILE;
        
        if (!is_file_image(file)) {
            message("Not importing %s: Not an image file", file.get_path());
            
            return ImportResult.NOT_AN_IMAGE;
        }

        if (!is_file_supported(file)) {
            message("Not importing %s: Unsupported extension", file.get_path());
            
            return ImportResult.UNSUPPORTED_FORMAT;
        }
        
        TimeVal timestamp;
        info.get_modification_time(out timestamp);
        
        // if all MD5s supplied, don't sniff for them
        if (params.exif_md5 != null && params.thumbnail_md5 != null && params.full_md5 != null)
            params.sniffer_options |= PhotoFileSniffer.Options.NO_MD5;
        
        // interrogate file for photo information
        PhotoFileInterrogator interrogator = new PhotoFileInterrogator(file, params.sniffer_options);
        try {
            interrogator.interrogate();
        } catch (Error err) {
            warning("Unable to interrogate photo file %s: %s", file.get_path(), err.message);
            
            return ImportResult.DECODE_ERROR;
        }
        
        // if not detected photo information, unsupported
        DetectedPhotoInformation? detected = interrogator.get_detected_photo_information();
        if (detected == null)
            return ImportResult.UNSUPPORTED_FORMAT;
        
        // copy over supplied MD5s if provided
        if ((params.sniffer_options & PhotoFileSniffer.Options.NO_MD5) != 0) {
            detected.exif_md5 = params.exif_md5;
            detected.thumbnail_md5 = params.thumbnail_md5;
            detected.md5 = params.full_md5;
        }
        
        Orientation orientation = Orientation.TOP_LEFT;
        time_t exposure_time = 0;
        string title = "";
        Rating rating = Rating.UNRATED;
        
#if TRACE_MD5
        debug("importing MD5 %s: exif=%s preview=%s full=%s", file.get_path(), detected.exif_md5,
            detected.thumbnail_md5, detected.md5);
#endif
        
        if (detected.metadata != null) {
            MetadataDateTime? date_time = detected.metadata.get_exposure_date_time();
            if (date_time != null)
                exposure_time = date_time.get_timestamp();
            
            orientation = detected.metadata.get_orientation();
            title = detected.metadata.get_title();
            params.keywords = detected.metadata.get_keywords();
            rating = detected.metadata.get_rating();
        }
        
        // verify basic mechanics of photo: RGB 8-bit encoding
        if (detected.colorspace != Gdk.Colorspace.RGB 
            || detected.channels < 3 
            || detected.bits_per_channel != 8) {
            message("Not importing %s: Unsupported color format", file.get_path());
            
            return ImportResult.UNSUPPORTED_FORMAT;
        }
        
        // photo information is initially stored in database in raw, non-modified format ... this is
        // especially important dealing with dimensions and orientation ... Don't trust EXIF
        // dimensions, they can lie or not be present
        params.row.photo_id = PhotoID();
        params.row.master.filepath = file.get_path();
        params.row.master.dim = detected.image_dim;
        params.row.master.filesize = info.get_size();
        params.row.master.timestamp = timestamp.tv_sec;
        params.row.exposure_time = exposure_time;
        params.row.orientation = orientation;
        params.row.master.original_orientation = orientation;
        params.row.import_id = params.import_id;
        params.row.event_id = EventID();
        params.row.transformations = null;
        params.row.md5 = detected.md5;
        params.row.thumbnail_md5 = detected.thumbnail_md5;
        params.row.exif_md5 = detected.exif_md5;
        params.row.time_created = 0;
        params.row.flags = 0;
        params.row.master.file_format = detected.file_format;
        params.row.title = title;
        params.row.rating = rating;
        
        if (params.thumbnails != null) {
            PhotoFileReader reader = params.row.master.file_format.create_reader(
                params.row.master.filepath);
            try {
                ThumbnailCache.generate_for_photo(params.thumbnails, reader, params.row.orientation, 
                    params.row.master.dim);
            } catch (Error err) {
                return ImportResult.convert_error(err, ImportResult.FILE_ERROR);
            }
        }
        
#if MEASURE_IMPORT
        debug("IMPORT: total=%lf", total_time.elapsed());
#endif
        return ImportResult.SUCCESS;
    }
    
    protected bool query_backing_photo_state(File file, PhotoFileSniffer.Options options,
        out BackingPhotoState state, out DetectedPhotoInformation detected) throws Error {
        // get basic file information
        FileInfo info = null;
        try {
            info = file.query_info(DirectoryMonitor.SUPPLIED_ATTRIBUTES,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        } catch (Error err) {
            critical("Unable to read file information for %s: %s", file.get_path(), err.message);
            
            return false;
        }
        
        // sniff photo information
        PhotoFileInterrogator interrogator = new PhotoFileInterrogator(file, options);
        interrogator.interrogate();
        detected = interrogator.get_detected_photo_information();
        if (detected == null) {
            critical("Photo update: %s no longer a recognized image", to_string());
            
            return false;
        }
        
        TimeVal modification_time = TimeVal();
        info.get_modification_time(out modification_time);
        
        state.filepath = file.get_path();
        state.timestamp = modification_time.tv_sec;
        state.filesize = info.get_size();
        state.file_format = detected.file_format;
        state.dim = detected.image_dim;
        state.original_orientation = detected.metadata != null
            ? detected.metadata.get_orientation() : Orientation.TOP_LEFT;
        
        return true;
    }
    
    // This method is thread-safe.  If returns false the photo should be marked offline (in the
    // main UI thread).
    public bool prepare_for_reimport_master(out PhotoRow updated_row, out PhotoMetadata metadata)
        throws Error {
        File file = get_master_reader().get_file();
        
        BackingPhotoState state = BackingPhotoState();
        DetectedPhotoInformation detected;
        if (!query_backing_photo_state(file, PhotoFileSniffer.Options.GET_ALL, out state, out detected)) {
            warning("Unable to retrieve photo state from %s for reimport", file.get_path());
            
            return false;
        }
        
        // verify basic mechanics of photo: RGB 8-bit encoding
        if (detected.colorspace != Gdk.Colorspace.RGB 
            || detected.channels < 3 
            || detected.bits_per_channel != 8) {
            warning("Not re-importing %s: Unsupported color format", file.get_path());
            
            return false;
        }
        
        // start with existing row and update appropriate fields
        lock (row) {
            updated_row = row;
        }
        
        updated_row.master = state;
        updated_row.md5 = detected.md5;
        updated_row.exif_md5 = detected.exif_md5;
        updated_row.thumbnail_md5 = detected.thumbnail_md5;
        updated_row.exposure_time = 0;
        updated_row.orientation = state.original_orientation;
        
        if (detected.metadata != null) {
            metadata = detected.metadata;
            
            MetadataDateTime? date_time = detected.metadata.get_exposure_date_time();
            if (date_time != null)
                updated_row.exposure_time = date_time.get_timestamp();
            
            updated_row.title = detected.metadata.get_title();
            updated_row.rating = detected.metadata.get_rating();
        } else {
            metadata = null;
        }
        
        return true;
    }
    
    protected abstract void apply_user_metadata_for_reimport(PhotoMetadata metadata);
    
    // This method is not thread-safe and should be called in the main thread.
    public void finish_reimport_master(ref PhotoRow updated_row, PhotoMetadata? metadata)
        throws DatabaseError {
        PhotoTable.get_instance().reimport(ref updated_row);
        
        lock (row) {
            row = updated_row;
            internal_remove_all_transformations(false);
        }
        
        if (metadata != null)
            apply_user_metadata_for_reimport(metadata);
        
        string list = null;
        if (is_master_baseline())
            list = "image:master,image:baseline,metadata:title,metadata:orientation,"
                + "metadata:rating,metadata:exposure-time,metadata:md5";
        else
            list = "image:master,metadata:title,metadata:orientation,metadata:rating,"
                + "metadata:exposure-time,metadata:md5";
        
        notify_altered(new Alteration.from_list(list));
    }
    
    // This method is thread-safe.  Returns false if the photo has no associated editable.
    public bool prepare_for_reimport_editable(out BackingPhotoState updated_state,
        out PhotoMetadata metadata) throws Error {
        File? file = get_editable_file();
        if (file == null)
            return false;
        
        DetectedPhotoInformation detected;
        if (!query_backing_photo_state(file, PhotoFileSniffer.Options.NO_MD5, out updated_state,
            out detected)) {
            return false;
        }
        
        // verify basic mechanics of photo: RGB 8-bit encoding
        if (detected.colorspace != Gdk.Colorspace.RGB 
            || detected.channels < 3 
            || detected.bits_per_channel != 8) {
            warning("Not re-importing %s: Unsupported color format", file.get_path());
            
            return false;
        }
        
        metadata = detected.metadata;
        
        return true;
    }
    
    // This method is not thread-safe.  It should be called by the main thread.
    public void finish_reimport_editable(BackingPhotoState updated_state, PhotoMetadata? metadata)
        throws DatabaseError {
        BackingPhotoID editable_id = get_editable_id();
        if (editable_id.is_invalid())
            return;
        
        BackingPhotoTable.get_instance().update(editable_id, updated_state);
        
        lock (row) {
            editable = updated_state;
            set_orientation(updated_state.original_orientation);
            internal_remove_all_transformations(false);
        }
        
        if (metadata != null) {
            set_title(metadata.get_title());
            set_rating(metadata.get_rating());
            apply_user_metadata_for_reimport(metadata);
        }
        
        notify_altered(new Alteration.from_list(
            "image:editable,image:baseline,metadata:title,metadata:orientation,"
            + "metadata:rating,metadata:exposure-time"));
    }
    
    public override string? get_unique_thumbnail_name() {
        return ("thumb%016" + int64.FORMAT_MODIFIER + "x").printf(get_photo_id().id);
    }
    
    // Use this only if the master file's modification time has been changed (i.e. touched)
    public void update_master_modification_time(FileInfo info) throws DatabaseError {
        TimeVal modification;
        info.get_modification_time(out modification);
        
        bool altered = false;
        lock (row) {
            if (row.master.timestamp != modification.tv_sec) {
                PhotoTable.get_instance().update_timestamp(row.photo_id, modification.tv_sec);
                row.master.timestamp = modification.tv_sec;
                altered = true;
            }
        }
        
        if (altered) {
            if (is_master_baseline())
                notify_altered(new Alteration.from_list("metadata:master-timestamp,metadata:baseline-timestamp"));
            else
                notify_altered(new Alteration("metadata", "master-timestamp"));
        }
    }
    
    // Most useful if the appropriate SourceCollection is frozen while calling this.
    public static void update_many_master_timestamps(Gee.Map<Photo, FileInfo> map)
        throws DatabaseError {
        PhotoTable.get_instance().begin_transaction();
        foreach (Photo photo in map.keys)
            photo.update_master_modification_time(map.get(photo));
        PhotoTable.get_instance().commit_transaction();
    }
    
    // Use this only if the editable file's modification time has been changed (i.e. touched)
    public void update_editable_modification_time(FileInfo info) throws DatabaseError {
        TimeVal modification;
        info.get_modification_time(out modification);
        
        bool altered = false;
        lock (row) {
            if (row.editable_id.is_valid() && editable.timestamp != modification.tv_sec) {
                BackingPhotoTable.get_instance().update_timestamp(row.editable_id,
                    modification.tv_sec);
                editable.timestamp = modification.tv_sec;
                altered = true;
            }
        }
        
        if (altered)
            notify_altered(new Alteration.from_list("metadata:editable-timestamp,metadata:baseline-timestamp"));
    }
    
    // Most useful if the appropriate SourceCollection is frozen while calling this.
    public static void update_many_editable_timestamps(Gee.Map<Photo, FileInfo> map)
        throws DatabaseError {
        PhotoTable.get_instance().begin_transaction();
        foreach (Photo photo in map.keys)
            photo.update_editable_modification_time(map.get(photo));
        PhotoTable.get_instance().commit_transaction();
    }
    
    public override PhotoFileFormat get_preferred_thumbnail_format() {
        return (get_file_format().can_write()) ? get_file_format() :
            PhotoFileFormat.get_system_default_format();
    }

    public override Gdk.Pixbuf? create_thumbnail(int scale) throws Error {
        return get_pixbuf(Scaling.for_best_fit(scale, true));
    }

    public static bool is_file_supported(File file) {
        return is_basename_supported(file.get_basename());
    }
    
    public static bool is_basename_supported(string basename) {
        string name, ext;
        disassemble_filename(basename, out name, out ext);
        if (ext == null)
            return false;
        
        // treat extensions as case-insensitive
        ext = ext.down();
        
        // search support file formats
        foreach (PhotoFileFormat file_format in PhotoFileFormat.get_supported()) {
            if (file_format.get_properties().is_recognized_extension(ext))
                return true;
        }
        
        return false;
    }
    
    public static bool is_file_image(File file) {
        return is_extension_found(file.get_basename(), IMAGE_EXTENSIONS);
    }
    
    private static bool is_extension_found(string basename, string[] extensions) {
        string name, ext;
        disassemble_filename(basename, out name, out ext);
        if (ext == null)
            return false;
        
        // treat extensions as case-insensitive
        ext = ext.down();
        
        // search supported list
        foreach (string extension in extensions) {
            if (ext == extension)
                return true;
        }
        
        return false;
    }
    
    // This is not thread-safe.  Obviously, at least one field must be non-null for this to be
    // effective, although there is no guarantee that any one will be sufficient.  file_format
    // should be UNKNOWN if not to require matching file formats.
    public static bool is_duplicate(File? file, string? thumbnail_md5, string? full_md5,
        PhotoFileFormat file_format) {
#if !NO_DUPE_DETECTION
        return PhotoTable.get_instance().has_duplicate(file, thumbnail_md5, full_md5, file_format);
#else
        return false;
#endif
    }
    
    protected static PhotoID[]? get_duplicate_ids(File? file, string? thumbnail_md5, string? full_md5,
        PhotoFileFormat file_format) {
#if !NO_DUPE_DETECTION
        return PhotoTable.get_instance().get_duplicate_ids(file, thumbnail_md5, full_md5, file_format);
#else
        return null;
#endif
    }
    
    // Conforms to GetDatabaseSourceKey
    public static int64 get_photo_key(DataSource source) {
        return ((LibraryPhoto) source).get_photo_id().id;
    }
    
    // Data element accessors ... by making these thread-safe, and by the remainder of this class
    // (and subclasses) accessing row *only* through these, helps ensure this object is suitable
    // for threads.  This implementation is specifically for PixbufCache to work properly.
    //
    // Much of the setter's thread-safety (especially in regard to writing to the database) is
    // that there is a single Photo object per row of the database.  The PhotoTable is accessed
    // elsewhere in the system (usually for aggregate and search functions).  Those would need to
    // be factored and locked in order to guarantee full thread safety.
    //
    // Also note there is a certain amount of paranoia here.  Many of PhotoRow's elements are
    // currently static, with no setters to change them.  However, since some of these may become
    // mutable in the future, the entire structure is locked.  If performance becomes an issue,
    // more fine-tuned locking may be implemented -- another reason to *only* use these getters
    // and setters inside this class.
    
    public override File get_file() {
        return get_source_reader().get_file();
    }
    
    // This should only be used when the photo's master backing file has been renamed; if it's been
    // altered, use update().
    public void set_master_file(File file) {
        string filepath = file.get_path();
        
        bool altered = false;
        bool is_baseline = false;
        bool name_changed = false;
        File? old_file = null;
        try {
            lock (row) {
                lock (readers) {
                    old_file = readers.master.get_file();
                    if (!file.equal(old_file)) {
                        PhotoTable.get_instance().set_filepath(get_photo_id(), filepath);
                        
                        row.master.filepath = filepath;
                        file_title = file.get_basename();
                        readers.master = row.master.file_format.create_reader(filepath);
                        
                        altered = true;
                        is_baseline = is_master_baseline();
                        name_changed = is_string_empty(row.title);
                    }
                }
            }
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        }
        
        if (altered) {
            notify_master_replaced(old_file, file);
            
            if (is_baseline)
                notify_baseline_replaced();
            
            // because the name of the photo is determined by its file title if no user title is present,
            // signal metadata has altered
            if (name_changed)
                notify_altered(new Alteration("metadata", "name"));
        }
    }
    
    // This should only be used when the photo's editable file has been renamed.  If it's been
    // altered, use update().  DO NOT USE THIS TO ATTACH A NEW EDITABLE FILE TO THE PHOTO.
    public void set_editable_file(File file) {
        string filepath = file.get_path();
        
        bool altered = false;
        bool is_baseline = false;
        File? old_file = null;
        try {
            lock (row) {
                lock (readers) {
                    old_file = (readers.editable != null) ? readers.editable.get_file() : null;
                    if (old_file != null && !old_file.equal(file)) {
                        BackingPhotoTable.get_instance().set_filepath(row.editable_id, filepath);
                        
                        editable.filepath = filepath;
                        readers.editable = editable.file_format.create_reader(filepath);
                        
                        altered = true;
                        is_baseline = is_editable_baseline();
                    }
                }
            }
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        }
        
        if (altered) {
            notify_editable_replaced(old_file, file);
            
            if (is_baseline)
                notify_baseline_replaced();
        }
    }
    
    // Returns the file generating pixbufs, that is, the mimic or baseline if present, the backing
    // file if not.
    public File get_actual_file() {
        return get_baseline_reader().get_file();
    }
    
    public File get_master_file() {
        return get_master_reader().get_file();
    }
    
    public File? get_editable_file() {
        PhotoFileReader? reader = get_editable_reader();
        
        return reader != null ? reader.get_file() : null;
    }
    
    public PhotoFileFormat get_file_format() {
        lock (row) {
            return backing_photo_state->file_format;
        }
    }
    
    public PhotoFileFormat get_master_file_format() {
        lock (row) {
            return readers.master.get_file_format();
        }
    }
    
    public time_t get_timestamp() {
        lock (row) {
            return backing_photo_state->timestamp;
        }
    }

    public PhotoID get_photo_id() {
        lock (row) {
            return row.photo_id;
        }
    }
    
    // This is NOT thread-safe.
    public inline EventID get_event_id() {
        return row.event_id;
    }
    
    // This is NOT thread-safe.
    public inline int64 get_raw_event_id() {
        return row.event_id.id;
    }
    
    public ImportID get_import_id() {
        lock (row) {
            return row.import_id;
        }
    }
    
    protected BackingPhotoID get_editable_id() {
        lock (row) {
            return row.editable_id;
        }
    }
    
    public string get_master_md5() {
        lock (row) {
            return row.md5;
        }
    }
    
    // Flags' meanings are determined by subclasses.  Top 16 flags (0xFFFF000000000000) reserved
    // for Photo.
    public uint64 get_flags() {
        lock (row) {
            return row.flags;
        }
    }
    
    public uint64 replace_flags(uint64 flags) {
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().replace_flags(get_photo_id(), flags);
            if (committed)
                row.flags = flags;
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "flags"));
        
        return flags;
    }
    
    public bool is_flag_set(uint64 mask) {
        lock (row) {
            return (row.flags & mask) != 0;
        }
    }
    
    public uint64 add_flags(uint64 mask) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = row.flags | mask;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().replace_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "flags"));
        
        return flags;
    }
    
    public uint64 remove_flags(uint64 mask) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = row.flags & ~mask;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().replace_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "flags"));
        
        return flags;
    }
    
    public uint64 add_remove_flags(uint64 add, uint64 remove) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = (row.flags | add) & ~remove;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().replace_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "flags"));
        
        return flags;
    }
    
    public static void add_remove_many_flags(Gee.Collection<Photo>? add, uint64 add_mask,
        Gee.Collection<Photo>? remove, uint64 remove_mask) throws DatabaseError {
        PhotoTable.get_instance().begin_transaction();
        
        if (add != null) {
            foreach (Photo photo in add)
                photo.add_flags(add_mask);
        }
        
        if (remove != null) {
            foreach (Photo photo in remove)
                photo.remove_flags(remove_mask);
        }
        
        PhotoTable.get_instance().commit_transaction();
    }
    
    public uint64 toggle_flags(uint64 mask) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = row.flags ^ mask;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().replace_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "flags"));
        
        return flags;
    }

    public Rating get_rating() {
        lock (row) {
            return row.rating;
        }
    }

    public void set_rating(Rating rating) {
        bool committed = false;
    
        lock (row) {
            if (rating != row.rating && rating.is_valid()) {  
    
                committed = PhotoTable.get_instance().set_rating(get_photo_id(), rating);
                if (committed)
                    row.rating = rating;
            }
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "rating"));
    }

    public void increase_rating() {
        lock (row) {
            set_rating(row.rating.increase());
        }
    }

    public void decrease_rating() {
        lock (row) {
            set_rating(row.rating.decrease());
        }
    }
    
    protected override void commit_backlinks(SourceCollection? sources, string? backlinks) {
        // For now, only one link state may be stored in the database ... if this turns into a
        // problem, will use SourceCollection to determine where to store it.
        
        try {
            PhotoTable.get_instance().update_backlinks(get_photo_id(), backlinks);
            lock (row) {
                row.backlinks = backlinks;
            }
        } catch (DatabaseError err) {
            warning("Unable to update link state for %s: %s", to_string(), err.message);
        }
        
        // Note: *Not* firing altered or metadata_altered signal because link_state is not a
        // property that's available to users of Photo.  Persisting it as a mechanism for deaing 
        // with unlink/relink properly.
    }
    
    // This is NOT thread-safe.
    public Event? get_event() {
        EventID event_id = get_event_id();
        
        return event_id.is_valid() ? Event.global.fetch(event_id) : null;
    }
    
    // This is NOT thread-safe.
    public bool set_event(Event? event) {
        EventID event_id = (event != null) ? event.get_event_id() : EventID();
        if (row.event_id.id == event_id.id)
            return true;
        
        Event? old_event = get_event();
        
        bool committed = PhotoTable.get_instance().set_event(row.photo_id, event_id);
        if (committed) {
            if (old_event != null)
                old_event.detach(this);
            
            row.event_id = event_id;
            
            if (event != null)
                event.attach(this);
            
            notify_altered(new Alteration("metadata", "event"));
        }
        
        return committed;
    }
    
    // Best to freeze the appropriate SourceCollection as well.
    public static void set_many_to_event(Gee.Collection<Photo> photos, Event? event) {
        EventID event_id = (event != null) ? event.get_event_id() : EventID();
        
        PhotoID[] photo_ids = new PhotoID[photos.size];
        int ctr = 0;
        foreach (Photo photo in photos) {
            Event? old_event = photo.get_event();
            if (old_event != null)
                old_event.detach(photo);
            
            photo_ids[ctr++] = photo.row.photo_id;
            photo.row.event_id = event_id;
        }
        
        try {
            PhotoTable.get_instance().set_many_to_event(photo_ids, event_id);
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        }
        
        if (event != null)
            event.attach_many(photos);
        
        Alteration alteration = new Alteration("metadata", "event");
        foreach (Photo photo in photos)
            photo.notify_altered(alteration);
    }
    
    public override string to_string() {
        return "[%lld] %s%s".printf(get_photo_id().id, get_master_reader().get_filepath(),
            !is_master_baseline() ? " (" + get_actual_file().get_path() + ")" : "");
    }

    public override bool equals(DataSource? source) {
        // Primary key is where the rubber hits the road
        Photo? photo = source as Photo;
        if (photo != null) {
            PhotoID photo_id = get_photo_id();
            PhotoID other_photo_id = photo.get_photo_id();
            
            if (this != photo && photo_id.id != PhotoID.INVALID) {
                assert(photo_id.id != other_photo_id.id);
            }
        }
        
        return base.equals(source);
    }
    
    // used to update the database after an internal metadata exif write
    private void file_exif_updated() {
        File file = get_file();
    
        FileInfo info = null;
        try {
            info = file.query_info(DirectoryMonitor.SUPPLIED_ATTRIBUTES,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        } catch (Error err) {
            error("Unable to read file information for %s: %s", to_string(), err.message);
        }
        
        TimeVal timestamp = TimeVal();
        info.get_modification_time(out timestamp);
        
        // interrogate file for photo information
        PhotoFileInterrogator interrogator = new PhotoFileInterrogator(file);
        try {
            interrogator.interrogate();
        } catch (Error err) {
            warning("Unable to interrogate photo file %s: %s", file.get_path(), err.message);
        }
        
        DetectedPhotoInformation? detected = interrogator.get_detected_photo_information();
        if (detected == null) {
            critical("file_exif_updated: %s no longer an image", to_string());
            
            return;
        }
        
        bool success;
        lock (row) {
            success = PhotoTable.get_instance().master_exif_updated(get_photo_id(), info.get_size(),
                timestamp.tv_sec, detected.md5, detected.exif_md5, detected.thumbnail_md5, ref row);
        }
        
        if (success)
            notify_altered(new Alteration.from_list("metadata:exif,metadata:md5"));
    }

    // PhotoSource
    
    public override string get_name() {
        lock (row) {
            return !is_string_empty(row.title) ? row.title : file_title;
        }
    }
    
    public override uint64 get_filesize() {
        lock (row) {
            return backing_photo_state->filesize;
        }
    }
    
    public override time_t get_exposure_time() {
        lock (row) {
            return row.exposure_time;
        }
    }

    public string? get_title() {
        lock (row) {
            return row.title;
        }
    }

    public void set_title(string? title) {
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_title(row.photo_id, title);
            if (committed)
                row.title = title;
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "name"));
    }
    
    public void set_import_id(ImportID import_id) {
        DatabaseError dberr = null;
        lock (row) {
            try {
                PhotoTable.get_instance().set_import_id(row.photo_id, import_id);
                row.import_id = import_id;
            } catch (DatabaseError err) {
                dberr = err;
            }
        }
        
        if (dberr == null)
            notify_altered(new Alteration("metadata", "import-id"));
        else
            warning("Unable to write import ID for %s: %s", to_string(), dberr.message);
    }

    public void set_title_persistent(string? title) throws Error {
        PhotoFileReader source = get_source_reader();
        
        // Try to write to backing file
        if (!source.get_file_format().can_write()) {
            warning("No photo file writer available for %s", source.get_filepath());
            
            set_title(title);
            
            return;
        }
        
        PhotoMetadata metadata = source.read_metadata();
        metadata.set_title(title, true);
        
        PhotoFileWriter writer = source.create_writer();
        writer.write_metadata(metadata);
        
        set_title(title);
        
        file_exif_updated();
    }

    public void set_exposure_time(time_t time) {
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_exposure_time(row.photo_id, time);
            if (committed)
                row.exposure_time = time;
        }
        
        if (committed)
            notify_altered(new Alteration("metadata", "exposure-time"));
    }
    
    public void set_exposure_time_persistent(time_t time) throws Error {
        PhotoFileReader source = get_source_reader();
        
        // Try to write to backing file
        if (!source.get_file_format().can_write()) {
            warning("No photo file writer available for %s", source.get_filepath());
            
            set_exposure_time(time);
            
            return;
        }
        
        PhotoMetadata metadata = source.read_metadata();
        metadata.set_exposure_date_time(new MetadataDateTime(time));
        
        PhotoFileWriter writer = source.create_writer();
        writer.write_metadata(metadata);
        
        set_exposure_time(time);
        
        file_exif_updated();
    }
    
    // Returns cropped and rotated dimensions
    public override Dimensions get_dimensions() {
        Box crop;
        if (get_crop(out crop))
            return crop.get_dimensions();
        
        return get_original_dimensions();
    }
    
    // This method *must* be called with row locked.
    private void locked_create_adjustments_from_data() {
        adjustments = new PixelTransformationBundle();
        
        KeyValueMap map = get_transformation("adjustments");
        if (map == null)
            adjustments.set_to_identity();
        else
            adjustments.load(map);
        
        transformer = adjustments.generate_transformer();
    }
    
    // Returns a copy of the color adjustments array.  Use set_color_adjustments to persist.
    public PixelTransformationBundle get_color_adjustments() {
        lock (row) {
            if (adjustments == null)
                locked_create_adjustments_from_data();
            
            return adjustments.copy();
        }
    }
    
    public PixelTransformer get_pixel_transformer() {
        lock (row) {
            if (transformer == null)
                locked_create_adjustments_from_data();
            
            return transformer.copy();
        }
    }

    public bool has_color_adjustments() {
        return has_transformation("adjustments");
    }
    
    public PixelTransformation? get_color_adjustment(PixelTransformationType type) {
        return get_color_adjustments().get_transformation(type);
    }

    public void set_color_adjustments(PixelTransformationBundle new_adjustments) {
        /* if every transformation in 'new_adjustments' is the identity, then just remove all
           adjustments from the database */
        if (new_adjustments.is_identity()) {
            bool result;
            lock (row) {
                result = remove_transformation("adjustments");
                adjustments = null;
                transformer = null;
            }
            
            if (result)
                notify_altered(new Alteration("image", "color-adjustments"));

            return;
        }
        
        // convert bundle to KeyValueMap, which can be saved in the database
        KeyValueMap map = new_adjustments.save("adjustments");
        
        bool committed;
        lock (row) {
            if (transformer == null || adjustments == null) {
                // create new 
                adjustments = new_adjustments.copy();
                transformer = new_adjustments.generate_transformer();
            } else {
                // replace existing
                foreach (PixelTransformation transformation in new_adjustments.get_transformations()) {
                    transformer.replace_transformation(
                        adjustments.get_transformation(transformation.get_transformation_type()),
                        transformation);
                }
                
                adjustments = new_adjustments.copy();
            }

            committed = set_transformation(map);
        }
        
        if (committed)
            notify_altered(new Alteration("image", "color-adjustments"));
    }
    
    public override PhotoMetadata? get_metadata() {
        try {
            return get_source_reader().read_metadata();
        } catch (Error err) {
            warning("Unable to load metadata: %s", err.message);
            
            return null;
        }
    }
    
    // Transformation storage and exporting

    public Dimensions get_raw_dimensions() {
        lock (row) {
            return backing_photo_state->dim;
        }
    }

    public bool has_transformations() {
        lock (row) {
            return (row.orientation != backing_photo_state->original_orientation) 
                ? true 
                : (row.transformations != null);
        }
    }
    
    public bool only_metadata_changed() {
        MetadataDateTime? date_time = null;
        
        PhotoMetadata? metadata = get_metadata();
        if (metadata != null)
            date_time = metadata.get_exposure_date_time();
        
        lock (row) {
            return row.transformations == null 
                && (row.orientation != backing_photo_state->original_orientation 
                || (date_time != null && row.exposure_time != date_time.get_timestamp()));
        }
    }
    
    public bool has_alterations() {
        MetadataDateTime? date_time = null;
        
        PhotoMetadata? metadata = get_metadata();
        if (metadata != null)
            date_time = metadata.get_exposure_date_time();
        
        lock (row) {
            return row.transformations != null 
                || row.orientation != backing_photo_state->original_orientation
                || (date_time != null && row.exposure_time != date_time.get_timestamp());
        }
    }
    
    public PhotoTransformationState save_transformation_state() {
        lock (row) {
            return new PhotoTransformationStateImpl(this, row.orientation,
                row.transformations,
                transformer != null ? transformer.copy() : null,
                adjustments != null ? adjustments.copy() : null);
        }
    }
    
    public bool load_transformation_state(PhotoTransformationState state) {
        PhotoTransformationStateImpl state_impl = state as PhotoTransformationStateImpl;
        if (state_impl == null)
            return false;
        
        Orientation saved_orientation = state_impl.get_orientation();
        Gee.HashMap<string, KeyValueMap>? saved_transformations = state_impl.get_transformations();
        PixelTransformer? saved_transformer = state_impl.get_transformer();
        PixelTransformationBundle? saved_adjustments = state_impl.get_color_adjustments();
        
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_transformation_state(row.photo_id,
                saved_orientation, saved_transformations);
            if (committed) {
                row.orientation = saved_orientation;
                row.transformations = saved_transformations;
                transformer = saved_transformer;
                adjustments = saved_adjustments;
            }
        }
        
        if (committed)
            notify_altered(new Alteration("image", "transformation-state"));
        
        return committed;
    }
    
    public void remove_all_transformations() {
        internal_remove_all_transformations(true);
    }
    
    private void internal_remove_all_transformations(bool notify) {
        bool is_altered = false;
        lock (row) {
            is_altered = PhotoTable.get_instance().remove_all_transformations(row.photo_id);
            row.transformations = null;
            
            transformer = null;
            adjustments = null;
            
            if (row.orientation != backing_photo_state->original_orientation) {
                PhotoTable.get_instance().set_orientation(row.photo_id, 
                    backing_photo_state->original_orientation);
                row.orientation = backing_photo_state->original_orientation;
                is_altered = true;
            }
        }

        if (is_altered && notify)
            notify_altered(new Alteration("image", "revert"));
    }
    
    public Orientation get_original_orientation() {
        lock (row) {
            return backing_photo_state->original_orientation;
        }
    }
    
    public Orientation get_orientation() {
        lock (row) {
            return row.orientation;
        }
    }
    
    public bool set_orientation(Orientation orientation) {
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_orientation(row.photo_id, orientation);
            if (committed)
                row.orientation = orientation;
        }
        
        if (committed)
            notify_altered(new Alteration("image", "orientation"));
        
        return committed;
    }

    public virtual void rotate(Rotation rotation) {
        lock (row) {
            set_orientation(get_orientation().perform(rotation));
        }
    }

    private bool has_transformation(string name) {
        lock (row) {
            return (row.transformations != null) ? row.transformations.has_key(name) : false;
        }
    }
    
    // Note that obtaining the proper map is thread-safe here.  The returned map is a copy of
    // the original, so it is thread-safe as well.  However: modifying the returned map
    // does not modify the original; set_transformation() must be used.
    private KeyValueMap? get_transformation(string name) {
        KeyValueMap map = null;
        lock (row) {
            if (row.transformations != null) {
                map = row.transformations.get(name);
                if (map != null)
                    map = map.copy();
            }
        }
        
        return map;
    }
    
    private bool set_transformation(KeyValueMap trans) {
        lock (row) {
            if (row.transformations == null)
                row.transformations = new Gee.HashMap<string, KeyValueMap>(str_hash, str_equal, direct_equal);
            
            row.transformations.set(trans.get_group(), trans);
            
            return PhotoTable.get_instance().set_transformation(row.photo_id, trans);
        }
    }

    private bool remove_transformation(string name) {
        bool altered_cache, altered_persistent;
        lock (row) {
            if (row.transformations != null) {
                altered_cache = row.transformations.unset(name);
                if (row.transformations.size == 0)
                    row.transformations = null;
            } else {
                altered_cache = false;
            }
            
            altered_persistent = PhotoTable.get_instance().remove_transformation(row.photo_id, 
                name);
        }

        return (altered_cache || altered_persistent);
    }

    public bool has_crop() {
        return has_transformation("crop");
    }

    // Returns the crop in the raw photo's coordinate system
    private bool get_raw_crop(out Box crop) {
        KeyValueMap map = get_transformation("crop");
        if (map == null)
            return false;
        
        int left = map.get_int("left", -1);
        int top = map.get_int("top", -1);
        int right = map.get_int("right", -1);
        int bottom = map.get_int("bottom", -1);
        
        if (left == -1 || top == -1 || right == -1 || bottom == -1)
            return false;
        
        crop = Box(left, top, right, bottom);
        
        return true;
    }
    
    // Sets the crop using the raw photo's unrotated coordinate system
    private void set_raw_crop(Box crop) {
        KeyValueMap map = new KeyValueMap("crop");
        map.set_int("left", crop.left);
        map.set_int("top", crop.top);
        map.set_int("right", crop.right);
        map.set_int("bottom", crop.bottom);
        
        if (set_transformation(map))
            notify_altered(new Alteration("image", "crop"));
    }
    
    // All instances are against the coordinate system of the unscaled, unrotated photo.
    private RedeyeInstance[] get_raw_redeye_instances() {
        KeyValueMap map = get_transformation("redeye");
        if (map == null)
            return new RedeyeInstance[0];
        
        int num_points = map.get_int("num_points", -1);
        assert(num_points > 0);

        RedeyeInstance[] res = new RedeyeInstance[num_points];

        Gdk.Point default_point = {0};
        default_point.x = -1;
        default_point.y = -1;

        for (int i = 0; i < num_points; i++) {
            string center_key = "center%d".printf(i);
            string radius_key = "radius%d".printf(i);

            res[i].center = map.get_point(center_key, default_point);
            assert(res[i].center.x != default_point.x);
            assert(res[i].center.y != default_point.y);

            res[i].radius = map.get_int(radius_key, -1);
            assert(res[i].radius != -1);
        }

        return res;
    }
    
    public bool has_redeye_transformations() {
        return has_transformation("redeye");
    }

    // All instances are against the coordinate system of the unrotated photo.
    private void add_raw_redeye_instance(RedeyeInstance redeye) {
        KeyValueMap map = get_transformation("redeye");
        if (map == null) {
            map = new KeyValueMap("redeye");
            map.set_int("num_points", 0);
        }
        
        int num_points = map.get_int("num_points", -1);
        assert(num_points >= 0);
        
        num_points++;
        
        string radius_key = "radius%d".printf(num_points - 1);
        string center_key = "center%d".printf(num_points - 1);
        
        map.set_int(radius_key, redeye.radius);
        map.set_point(center_key, redeye.center);
        
        map.set_int("num_points", num_points);

        if (set_transformation(map))
            notify_altered(new Alteration("image", "redeye"));
    }

    // Pixbuf generation
    
    // Returns dimensions for the pixbuf at various stages of the pipeline.
    //
    // scaled_image is the dimensions of the image after a scaled load-and-decode.
    // scaled_to_viewport is the dimensions of the image sized according to the scaling parameter.
    // scaled_image and scaled_to_viewport may be different if the photo is cropped.
    //
    // Returns true if scaling is to occur, false otherwise.  If false, scaled_image will be set to
    // the raw image dimensions and scaled_to_viewport will be the dimensions of the image scaled
    // to the Scaling viewport.
    private bool calculate_pixbuf_dimensions(Scaling scaling, Exception exceptions, 
        out Dimensions scaled_image, out Dimensions scaled_to_viewport) {
        lock (row) {
            // this function needs to access various elements of the Photo atomically
            return locked_calculate_pixbuf_dimensions(scaling, exceptions,
                out scaled_image, out scaled_to_viewport);
        }
    }
    
    // Must be called with row locked.
    private bool locked_calculate_pixbuf_dimensions(Scaling scaling, Exception exceptions,
        out Dimensions scaled_image, out Dimensions scaled_to_viewport) {
        Dimensions raw = get_raw_dimensions();
        
        if (scaling.is_unscaled()) {
            scaled_image = raw;
            scaled_to_viewport = raw;
            
            return false;
        }
        
        Orientation orientation = get_orientation();
        
        // If no crop, the scaled_image is simply raw scaled to fit into the viewport.  Otherwise,
        // the image is scaled enough so the cropped region fits the viewport.

        scaled_image = Dimensions();
        scaled_to_viewport = Dimensions();
        
        if (exceptions.allows(Exception.CROP)) {
            Box crop;
            if (get_raw_crop(out crop)) {
                // rotate the crop and raw space accordingly ... order is important here, rotate_box
                // works with the unrotated dimensions in space
                Dimensions rotated_raw = raw;
                if (exceptions.allows(Exception.ORIENTATION)) {
                    crop = orientation.rotate_box(raw, crop);
                    rotated_raw = orientation.rotate_dimensions(raw);
                }
                
                // scale the rotated crop to fit in the viewport
                Box scaled_crop = crop.get_scaled(scaling.get_scaled_dimensions(crop.get_dimensions()));
                
                // the viewport size is the size of the scaled crop
                scaled_to_viewport = scaled_crop.get_dimensions();
                    
                // only scale the image if the crop is larger than the viewport
                if (crop.get_width() <= scaled_crop.get_width() 
                    && crop.get_height() <= scaled_crop.get_height()) {
                    scaled_image = raw;
                    scaled_to_viewport = crop.get_dimensions();
                    
                    return false;
                }
                // resize the total pixbuf so the crop slices directly from the scaled pixbuf, 
                // with no need for resizing thereafter.  The decoded size is determined by the 
                // proportion of the actual size to the crop size
                scaled_image = rotated_raw.get_scaled_similar(crop.get_dimensions(), 
                    scaled_crop.get_dimensions());
                
                // derotate, as the loader knows nothing about orientation
                if (exceptions.allows(Exception.ORIENTATION))
                    scaled_image = orientation.derotate_dimensions(scaled_image);
            }
        }
        
        // if scaled_image not set, merely scale the raw pixbuf
        if (!scaled_image.has_area()) {
            // rotate for the scaler
            Dimensions rotated_raw = raw;
            if (exceptions.allows(Exception.ORIENTATION))
                rotated_raw = orientation.rotate_dimensions(raw);

            scaled_image = scaling.get_scaled_dimensions(rotated_raw);
            scaled_to_viewport = scaled_image;
        
            // derotate the scaled dimensions, as the loader knows nothing about orientation
            if (exceptions.allows(Exception.ORIENTATION))
                scaled_image = orientation.derotate_dimensions(scaled_image);
        }

        // do not scale up
        if (scaled_image.width >= raw.width && scaled_image.height >= raw.height) {
            scaled_image = raw;
            
            return false;
        }
        
        assert(scaled_image.has_area());
        assert(scaled_to_viewport.has_area());
        
        return true;
    }

    // Returns a raw, untransformed, unrotated pixbuf directly from the source.  Scaling provides
    // asked for a scaled-down image, which has certain performance benefits if the resized
    // JPEG is scaled down by a factor of a power of two (one-half, one-fourth, etc.).
    private Gdk.Pixbuf load_raw_pixbuf(Scaling scaling, Exception exceptions,
        BackingFetchMode fetch_mode = BackingFetchMode.BASELINE) throws Error {
        
        PhotoFileReader loader = get_backing_reader(fetch_mode);
        
        // no scaling, load and get out
        if (scaling.is_unscaled()) {
#if MEASURE_PIPELINE
            debug("LOAD_RAW_PIXBUF UNSCALED %s: requested", loader.get_filepath());
#endif
            
            return loader.unscaled_read();
        }
        
        // Need the dimensions of the image to load
        Dimensions scaled_image, scaled_to_viewport;
        bool is_scaled = calculate_pixbuf_dimensions(scaling, exceptions, out scaled_image, 
            out scaled_to_viewport);
        if (!is_scaled) {
#if MEASURE_PIPELINE
            debug("LOAD_RAW_PIXBUF UNSCALED %s: scaling unavailable", loader.get_filepath());
#endif
            
            return loader.unscaled_read();
        }
        
        Gdk.Pixbuf pixbuf = loader.scaled_read(get_raw_dimensions(), scaled_image);
        
#if MEASURE_PIPELINE
        debug("LOAD_RAW_PIXBUF %s %s: %s -> %s (actual: %s)", scaling.to_string(), loader.get_filepath(),
            get_raw_dimensions().to_string(), scaled_image.to_string(), 
            Dimensions.for_pixbuf(pixbuf).to_string());
#endif
        
        assert(scaled_image.approx_equals(Dimensions.for_pixbuf(pixbuf), SCALING_FUDGE));
        
        return pixbuf;
    }

    // Returns a raw, untransformed, scaled pixbuf from the master that has been optionally rotated
    // according to its original EXIF settings.
    public Gdk.Pixbuf get_master_pixbuf(Scaling scaling, bool rotate = true) throws Error {
#if MEASURE_PIPELINE
        Timer timer = new Timer();
        Timer total_timer = new Timer();
        double orientation_time = 0.0;
        
        total_timer.start();
#endif
        // get required fields all at once, to avoid holding the row lock
        Dimensions scaled_image, scaled_to_viewport;
        Orientation original_orientation;
        
        lock (row) {
            calculate_pixbuf_dimensions(scaling, Exception.NONE, out scaled_image, 
                out scaled_to_viewport);
            original_orientation = get_original_orientation();
        }
        
        // load-and-decode and scale
        Gdk.Pixbuf pixbuf = load_raw_pixbuf(scaling, Exception.NONE, BackingFetchMode.MASTER);
            
        // orientation
#if MEASURE_PIPELINE
        timer.start();
#endif
        if (rotate)
            pixbuf = original_orientation.rotate_pixbuf(pixbuf);
#if MEASURE_PIPELINE
        orientation_time = timer.elapsed();
        
        debug("MASTER PIPELINE %s (%s): orientation=%lf total=%lf", to_string(), scaling.to_string(),
            orientation_time, total_timer.elapsed());
#endif
        
        return pixbuf;
    }

    // A preview pixbuf is one that can be quickly generated and scaled as a preview.  It is fully 
    // transformed.
    //
    // Note that an unscaled scaling is not considered a performance-killer for this method, 
    // although the quality of the pixbuf may be quite poor compared to the actual unscaled 
    // transformed pixbuf.
    public abstract Gdk.Pixbuf get_preview_pixbuf(Scaling scaling) throws Error;
    
    public override Gdk.Pixbuf get_pixbuf(Scaling scaling) throws Error {
        return get_pixbuf_with_options(scaling);
    }
    
    // Returns a fully transformed and scaled pixbuf.  Transformations may be excluded via the mask.
    // If the image is smaller than the scaling, it will be returned in its actual size.  The
    // caller is responsible for scaling thereafter.
    //
    // Note that an unscaled fetch can be extremely expensive, and it's far better to specify an 
    // appropriate scale.
    public Gdk.Pixbuf get_pixbuf_with_options(Scaling scaling, Exception exceptions =
        Exception.NONE, BackingFetchMode fetch_mode = BackingFetchMode.BASELINE) throws Error {
#if MEASURE_PIPELINE
        Timer timer = new Timer();
        Timer total_timer = new Timer();
        double redeye_time = 0.0, crop_time = 0.0, adjustment_time = 0.0, orientation_time = 0.0;

        total_timer.start();
#endif
        // to minimize holding the row lock, fetch everything needed for the pipeline up-front
        bool is_scaled, is_cropped;
        Dimensions scaled_image, scaled_to_viewport;
        Dimensions original = Dimensions();
        Dimensions scaled = Dimensions();
        RedeyeInstance[] redeye_instances = null;
        Box crop;
        PixelTransformer transformer = null;
        Orientation orientation;
        
        lock (row) {
            // it's possible for get_raw_pixbuf to not return an image scaled to the spec'd scaling,
            // particularly when the raw crop is smaller than the viewport
            is_scaled = calculate_pixbuf_dimensions(scaling, exceptions, out scaled_image,
                out scaled_to_viewport);
            
            if (is_scaled)
                original = get_raw_dimensions();
            
            redeye_instances = get_raw_redeye_instances();
            
            is_cropped = get_raw_crop(out crop);
            
            if (has_color_adjustments())
                transformer = get_pixel_transformer();
            
            orientation = get_orientation();
        }
        
        //
        // Image load-and-decode
        //
        
        Gdk.Pixbuf pixbuf = load_raw_pixbuf(scaling, exceptions, fetch_mode);
        
        if (is_scaled)
            scaled = Dimensions.for_pixbuf(pixbuf);
        
        //
        // Image transformation pipeline
        //
        
        // redeye reduction
        if (exceptions.allows(Exception.REDEYE)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            foreach (RedeyeInstance instance in redeye_instances) {
                // redeye is stored in raw coordinates; need to scale to scaled image coordinates
                if (is_scaled) {
                    instance.center = coord_scaled_in_space(instance.center.x, instance.center.y, 
                        original, scaled);
                    instance.radius = radius_scaled_in_space(instance.radius, original, scaled);
                    assert(instance.radius != -1);
                }
                
                pixbuf = do_redeye(pixbuf, instance);
            }
#if MEASURE_PIPELINE
            redeye_time = timer.elapsed();
#endif
        }

        // crop
        if (exceptions.allows(Exception.CROP)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            if (is_cropped) {
                // crop is stored in raw coordinates; need to scale to scaled image coordinates;
                // also, no need to do this if the image itself was unscaled (which can happen
                // if the crop is smaller than the viewport)
                if (is_scaled)
                    crop = crop.get_scaled_similar(original, scaled);
                
                pixbuf = new Gdk.Pixbuf.subpixbuf(pixbuf, crop.left, crop.top, crop.get_width(),
                    crop.get_height());
            }

#if MEASURE_PIPELINE
            crop_time = timer.elapsed();
#endif
        }
        
        // color adjustment
        if (exceptions.allows(Exception.ADJUST)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            if (transformer != null)
                transformer.transform_pixbuf(pixbuf);
#if MEASURE_PIPELINE
            adjustment_time = timer.elapsed();
#endif
        }

        // orientation (all modifications are stored in unrotated coordinate system)
        if (exceptions.allows(Exception.ORIENTATION)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            pixbuf = orientation.rotate_pixbuf(pixbuf);
#if MEASURE_PIPELINE
            orientation_time = timer.elapsed();
#endif
        }
        
        // this is to verify the generated pixbuf matches the scale requirements; crop and 
        // orientation are the only transformations that change the dimensions of the pixbuf, and
        // must be accounted for the test to be valid
        if (is_scaled)
            assert(scaled_to_viewport.approx_equals(Dimensions.for_pixbuf(pixbuf), SCALING_FUDGE));
        
#if MEASURE_PIPELINE
        debug("PIPELINE %s (%s): redeye=%lf crop=%lf adjustment=%lf orientation=%lf total=%lf",
            to_string(), scaling.to_string(), redeye_time, crop_time, adjustment_time, 
            orientation_time, total_timer.elapsed());
#endif
        
        return pixbuf;
    }
    
    //
    // File export
    //
    
    protected abstract bool has_user_generated_metadata();
    
    // Sets the metadata values for any user generated metadata, only called if
    // has_user_generated_metadata returns true
    protected abstract void set_user_metadata_for_export(PhotoMetadata metadata);
    
    // Returns the basename of the file if it were to be exported in format 'file_format'; if
    // 'file_format' is null, then return the basename of the file if it were to be exported in the
    // native backing format of the photo (i.e. no conversion is performed). If 'file_format' is
    // null and the native backing format is not writeable (i.e. RAW), then use the system
    // default file format, as defined in PhotoFileFormat
    public string get_export_basename(PhotoFileFormat? file_format = null) {
        if (file_format != null) {
            return file_format.get_properties().convert_file_extension(get_master_file()).get_basename();
        } else {
            if (get_file_format().can_write()) {
                return get_file_format().get_properties().convert_file_extension(
                    get_master_file()).get_basename();
            } else {
                return PhotoFileFormat.get_system_default_format().get_properties().convert_file_extension(
                    get_master_file()).get_basename();
            }
        }
    }
    
    private bool export_fullsized_backing(File file) throws Error {
        // See if the native reader or the mimic supports writing ... if no matches, need to fall back
        // on a "regular" export, which requires decoding then encoding
        PhotoFileReader export_reader = null;
        bool is_master = true;
        lock (readers) {
            if (readers.editable != null && readers.editable.get_file_format().can_write()) {
                export_reader = readers.editable;
                is_master = false;
            } else if (readers.master.get_file_format().can_write()) {
                export_reader = readers.master;
            } else if (readers.mimic != null && readers.mimic.get_file_format().can_write()) {
                export_reader = readers.mimic;
                is_master = false;
            }
        }
        
        if (export_reader == null)
            return false;
        
        PhotoFileFormatProperties format_properties = export_reader.get_file_format().get_properties();
        
        // Build a destination file with the caller's name but the appropriate extension
        File dest_file = format_properties.convert_file_extension(file);
        
        // Create a PhotoFileWriter that matches the PhotoFileReader's file format
        PhotoFileWriter writer = export_reader.get_file_format().create_writer(dest_file.get_path());
        
        debug("Exporting full-sized copy of %s to %s", to_string(), writer.get_filepath());
        
        export_reader.get_file().copy(dest_file, 
            FileCopyFlags.OVERWRITE | FileCopyFlags.TARGET_DEFAULT_PERMS, null, null);

        // If asking for an full-sized file and there are no alterations (transformations or EXIF)
        // *and* this is a copy of the original backing *and* there's no user metadata or title, then done
        if (!has_alterations() && is_master && !has_user_generated_metadata() && (get_title() == null))
            return true;
        
        // copy over relevant metadata if possible, otherwise generate new metadata
        PhotoMetadata? metadata = export_reader.read_metadata();
        if (metadata == null)
            metadata = export_reader.get_file_format().create_metadata();
        
        debug("Updating metadata of %s", writer.get_filepath());
        
        if (get_exposure_time() != 0)
            metadata.set_exposure_date_time(new MetadataDateTime(get_exposure_time()));
        else
            metadata.set_exposure_date_time(null);
        
        metadata.set_title(get_title(), false);
        metadata.set_pixel_dimensions(get_dimensions()); // created by sniffing pixbuf not metadata
        metadata.set_orientation(get_orientation());
        
        if (get_orientation() != get_original_orientation())
            metadata.remove_exif_thumbnail();

        set_user_metadata_for_export(metadata);

        writer.write_metadata(metadata);
        
        return true;
    }
    
    // TODO: Lossless transformations, especially for mere rotations of JFIF files.
    //
    // This method is thread-safe.
    public void export(File dest_file, Scaling scaling, Jpeg.Quality quality,
        PhotoFileFormat export_format) throws Error {
        // Attempt to avoid decode/encoding cycle when exporting original-sized photos, as that
        // degrades image quality with JFIF format files. If alterations exist, but only EXIF has
        // changed and the user hasn't requested conversion between image formats, then just copy
        // the original file and update relevant EXIF.
        if (scaling.is_unscaled() && (!has_alterations() || only_metadata_changed()) &&
            (export_format == get_file_format())) {
            if (export_fullsized_backing(dest_file))
                return;
        }

        if (!export_format.can_write())
            export_format = PhotoFileFormat.get_system_default_format();

        PhotoFileWriter writer = export_format.create_writer(dest_file.get_path());

        debug("Saving transformed version of %s to %s in file format %s", to_string(),
            writer.get_filepath(), export_format.to_string());
        
        Gdk.Pixbuf pixbuf = get_pixbuf_with_options(scaling, Exception.NONE,
            BackingFetchMode.SOURCE);
        
        writer.write(pixbuf, quality);
        
        debug("Setting EXIF for %s", writer.get_filepath());
        
        // copy over existing metadata from source if available
        PhotoMetadata? metadata = get_metadata();
        if (metadata == null)
            metadata = export_format.create_metadata();
        
        metadata.set_title(get_title(), false);
        metadata.set_pixel_dimensions(Dimensions.for_pixbuf(pixbuf));
        metadata.set_orientation(Orientation.TOP_LEFT);

        if (get_exposure_time() != 0)
            metadata.set_exposure_date_time(new MetadataDateTime(get_exposure_time()));
        else
            metadata.set_exposure_date_time(null);
        metadata.remove_tag("Exif.Iop.RelatedImageWidth");
        metadata.remove_tag("Exif.Iop.RelatedImageHeight");
        metadata.remove_exif_thumbnail();

        if(has_user_generated_metadata())
            set_user_metadata_for_export(metadata);

        writer.write_metadata(metadata);
    }
    
    private File generate_new_editable_file(out PhotoFileFormat file_format) throws Error {
        File backing;
        lock (row) {
            file_format = get_file_format();
            backing = get_file();
        }
        
        if (!file_format.can_write())
            file_format = PhotoFileFormat.get_system_default_format();
        
        string name, ext;
        disassemble_filename(backing.get_basename(), out name, out ext);
        
        if (!file_format.get_properties().is_recognized_extension(ext))
            ext = file_format.get_properties().get_default_extension();
        
        string editable_basename = "%s_%s.%s".printf(name, _("modified"), ext);
        
        bool collision;
        return LibraryFiles.generate_unique_file_at(backing.get_parent(), editable_basename,
            out collision);
    }
    
    private static bool launch_editor(File file, PhotoFileFormat file_format) throws Error {
#if NO_RAW
        string commandline = Config.get_instance().get_external_photo_app();
#else
        string commandline = file_format == PhotoFileFormat.RAW ? Config.get_instance().get_external_raw_app() : 
            Config.get_instance().get_external_photo_app();
#endif

        if (is_string_empty(commandline))
            return false;
        
        AppInfo? app;
        try {
            app = AppInfo.create_from_commandline(commandline, "", 
                AppInfoCreateFlags.NONE);
        } catch (Error er) {
            app = null;
        }

        List<File> files = new List<File>();
        files.insert(file, -1);

        if (app != null)
            return app.launch(files, null);
        
        string[] argv = new string[2];
        argv[0] = commandline;
        argv[1] = file.get_path();

        Pid child_pid;

        return Process.spawn_async(
            get_root_directory(),
            argv,
            null, // environment
            SpawnFlags.SEARCH_PATH,
            null, // child setup
            out child_pid);
    }
    
    // NOTE: This is a dangerous command.  It's HIGHLY recommended that this only be used with
    // read-only PhotoFileFormats (i.e. RAW).  As of today, if the user edits their master file,
    // it's not detected by Shotwell and things start to tip wonky.
    public void open_master_with_external_editor() throws Error {
        launch_editor(get_master_file(), get_master_file_format());
    }
    
    public void open_with_external_editor() throws Error {
        File current_editable_file = null;
        File create_editable_file = null;
        PhotoFileFormat editable_file_format;
        lock (readers) {
            if (readers.editable != null)
                current_editable_file = readers.editable.get_file();
            
            if (current_editable_file == null)
                create_editable_file = generate_new_editable_file(out editable_file_format);
            else
                editable_file_format = readers.editable.get_file_format();
        }
        
        // if this isn't the first time but the file does not exist OR there are transformations
        // that need to be represented there, create a new one
        if (create_editable_file == null && current_editable_file != null && 
            (!current_editable_file.query_exists(null) || has_transformations()))
            create_editable_file = current_editable_file;
        
        // if creating a new edited file and can write to it, stop watching the old one
        if (create_editable_file != null && editable_file_format.can_write()) {
            halt_monitoring_editable();
            
            try {
                export(create_editable_file, Scaling.for_original(), Jpeg.Quality.MAXIMUM, 
                    editable_file_format);
            } catch (Error err) {
                // if an error is thrown creating the file, clean it up
                try {
                    create_editable_file.delete(null);
                } catch (Error delete_err) {
                    // ignored
                    warning("Unable to delete editable file %s after export error: %s", 
                        create_editable_file.get_path(), delete_err.message);
                }
                
                throw err;
            }
            
            // attach the editable file to the photo
            attach_editable(editable_file_format, create_editable_file);
            
            current_editable_file = create_editable_file;
        }
        
        assert(current_editable_file != null);
        
        // if not already monitoring, monitor now
        if (editable_monitor == null)
            start_monitoring_editable(current_editable_file);
        
        launch_editor(current_editable_file, get_file_format());
    }
    
    public void revert_to_master() {
        detach_editable(true, true);
    }
    
    private void start_monitoring_editable(File file) throws Error {
        halt_monitoring_editable();
        
        editable_monitor = file.monitor(FileMonitorFlags.NONE, null);
        editable_monitor.changed.connect(on_editable_file_changed);
    }
    
    private void halt_monitoring_editable() {
        if (editable_monitor == null)
            return;
        
        editable_monitor.changed.disconnect(on_editable_file_changed);
        editable_monitor.cancel();
        editable_monitor = null;
    }
    
    private void attach_editable(PhotoFileFormat file_format, File file) throws Error {
        // remove the transformations ... this must be done before attaching the editable, as these 
        // transformations are in the master's coordinate system, not the editable's ... don't 
        // notify photo is altered *yet* because update_editable will notify, and want to avoid 
        // stacking them up
        internal_remove_all_transformations(false);
        update_editable(false, file_format.create_reader(file.get_path()));
    }
    
    private void update_editable_attributes() throws Error {
        update_editable(true, null);
    }
    
    public void reimport_editable() throws Error {
        // remove transformations, for much the same reasons as attach_editable().
        internal_remove_all_transformations(false);
        update_editable(false, null);
    }
    
    // In general, because of the fragility of the order of operations and what's required where,
    // use one of the above wrapper functions to call this rather than call this directly.
    private void update_editable(bool only_attributes, PhotoFileReader? new_reader = null) throws Error {
        // only_attributes only available for updating existing editable
        assert((only_attributes && new_reader == null) || (!only_attributes));
        
        PhotoFileReader? old_reader = get_editable_reader();
        
        PhotoFileReader reader = new_reader ?? old_reader;
        if (reader == null) {
            detach_editable(false, true);
            
            return;
        }
        
        BackingPhotoID editable_id = get_editable_id();
        File file = reader.get_file();
        
        bool timestamp_changed = false;
        bool filesize_changed = false;
        if (only_attributes) {
            assert(editable_id.is_valid());
            
            FileInfo info;
            try {
                info = file.query_filesystem_info(DirectoryMonitor.SUPPLIED_ATTRIBUTES, null);
            } catch (Error err) {
                warning("Unable to read editable filesystem info for %s: %s", to_string(), err.message);
                detach_editable(false, true);
                
                return;
            }
            
            TimeVal timestamp;
            info.get_modification_time(out timestamp);
        
            BackingPhotoTable.get_instance().update_attributes(editable_id, timestamp.tv_sec,
                info.get_size());
            lock (row) {
                timestamp_changed = editable.timestamp != timestamp.tv_sec;
                filesize_changed = editable.filesize != info.get_size();
                
                editable.timestamp = timestamp.tv_sec;
                editable.filesize = info.get_size();
            }
        } else {
            BackingPhotoState state = BackingPhotoState();
            DetectedPhotoInformation detected;
            if (query_backing_photo_state(file, PhotoFileSniffer.Options.NO_MD5, out state,
                out detected)) {
                // decide if updating existing editable or attaching a new one
                if (editable_id.is_valid()) {
                    BackingPhotoTable.get_instance().update(editable_id, state);
                    lock (row) {
                        editable = state;
                        assert(backing_photo_state == &editable);
                        set_orientation(backing_photo_state->original_orientation);
                    }
                } else {
                    BackingPhotoRow editable_row = BackingPhotoTable.get_instance().add(state);
                    lock (row) {
                        PhotoTable.get_instance().attach_editable(ref row, editable_row.id);
                        editable = editable_row.state;
                        backing_photo_state = &editable;
                        set_orientation(backing_photo_state->original_orientation);
                    }
                }
            }
        }
        
        // if a new reader was specified, install that and begin using it
        if (new_reader != null) {
            lock (readers) {
                readers.editable = new_reader;
            }
        }
        
        if (!only_attributes && reader != old_reader) {
            notify_baseline_replaced();
            notify_editable_replaced(old_reader != null ? old_reader.get_file() : null,
                new_reader != null ? new_reader.get_file() : null);
        }
        
        Alteration alteration = null;
        if (timestamp_changed)
            alteration = new Alteration.from_list("metadata:editable-timestamp,metadata:baseline-timestamp");
        
        if (filesize_changed || new_reader != null) {
            Alteration changed_alteration = new Alteration.from_list("image:editable,image:baseline");
            alteration = (alteration == null) ? changed_alteration : alteration.compress(changed_alteration);
        }
        
        if (alteration != null)
            notify_altered(alteration);
    }
    
    private void detach_editable(bool delete_editable, bool remove_transformations) {
        halt_monitoring_editable();
        
        bool has_editable = false;
        File? editable_file = null;
        lock (readers) {
            if (readers.editable != null) {
                editable_file = readers.editable.get_file();
                readers.editable = null;
                has_editable = true;
            }
        }
        
        if (has_editable) {
            BackingPhotoID editable_id = BackingPhotoID();
            try {
                lock (row) {
                    editable_id = row.editable_id;
                    if (editable_id.is_valid())
                        PhotoTable.get_instance().detach_editable(ref row);
                    backing_photo_state = &row.master;
                }
            } catch (DatabaseError err) {
                warning("Unable to remove editable from PhotoTable: %s", err.message);
            }
            
            try {
                if (editable_id.is_valid())
                    BackingPhotoTable.get_instance().remove(editable_id);
            } catch (DatabaseError err) {
                warning("Unable to remove editable from BackingPhotoTable: %s", err.message);
            }
        }
        
        if (remove_transformations)
            internal_remove_all_transformations(false);
        
        if (has_editable) {
            notify_baseline_replaced();
            notify_editable_replaced(editable_file, null);
        }
        
        if (delete_editable && editable_file != null) {
            try {
                editable_file.trash(null);
            } catch (Error err) {
                warning("Unable to trash editable %s for %s: %s", editable_file.get_path(), to_string(),
                    err.message);
            }
        }
        
        if (has_editable || remove_transformations)
            notify_altered(new Alteration("image", "revert"));
    }
    
    private void on_editable_file_changed(File file, File? other_file, FileMonitorEvent event) {
        // This has some expense, but this assertion is important for a lot of sanity reasons.
        lock (readers) {
            assert(readers.editable != null && file.equal(readers.editable.get_file()));
        }
        
        debug("EDITABLE %s: %s", event.to_string(), file.get_path());
        
        switch (event) {
            case FileMonitorEvent.CHANGED:
            case FileMonitorEvent.CREATED:
                if (reimport_editable_scheduler == null) {
                    reimport_editable_scheduler = new OneShotScheduler("Photo.reimport_editable", 
                        on_reimport_editable);
                }
                
                reimport_editable_scheduler.after_timeout(1000, true);
            break;
            
            case FileMonitorEvent.ATTRIBUTE_CHANGED:
                if (update_editable_attributes_scheduler == null) {
                    update_editable_attributes_scheduler = new OneShotScheduler(
                        "Photo.update_editable_attributes", on_update_editable_attributes);
                }
                
                update_editable_attributes_scheduler.after_timeout(1000, true);
            break;
            
            case FileMonitorEvent.DELETED:
                if (remove_editable_scheduler == null) {
                    remove_editable_scheduler = new OneShotScheduler("Photo.remove_editable",
                        on_remove_editable);
                }
                
                remove_editable_scheduler.after_timeout(3000, true);
            break;
            
            case FileMonitorEvent.CHANGES_DONE_HINT:
            default:
                // ignored
            break;
        }
    }
    
    private void on_reimport_editable() {
        debug("Reimporting editable for %s", to_string());
        try {
            reimport_editable();
        } catch (Error err) {
            warning("Unable to reimport photo %s changed by external editor: %s",
                to_string(), err.message);
        }
    }
    
    private void on_update_editable_attributes() {
        debug("Updating editable attributes for %s", to_string());
        try {
            update_editable_attributes();
        } catch (Error err) {
            warning("Unable to update editable attributes: %s", err.message);
        }
    }
    
    private void on_remove_editable() {
        PhotoFileReader? reader = get_editable_reader();
        if (reader == null)
            return;
        
        File file = reader.get_file();
        if (file.query_exists(null)) {
            debug("Not removing editable for %s: file exists", to_string());
            
            return;
        }
        
        debug("Removing editable for %s: file no longer exists", to_string());
        detach_editable(false, true);
    }
    
    //
    // Aggregate/helper/translation functions
    //
    
    // Returns uncropped (but rotated) dimensions
    public Dimensions get_original_dimensions() {
        Dimensions dim = get_raw_dimensions();
        Orientation orientation = get_orientation();
        
        return orientation.rotate_dimensions(dim);
    }
    
    // Returns uncropped dimensions rotated only to reflect the original orientation
    public Dimensions get_master_dimensions() {
        return get_original_orientation().rotate_dimensions(get_raw_dimensions());
    }
    
    // Returns the crop against the coordinate system of the rotated photo
    public bool get_crop(out Box crop) {
        Box raw;
        if (!get_raw_crop(out raw))
            return false;
        
        Dimensions dim = get_raw_dimensions();
        Orientation orientation = get_orientation();
        
        crop = orientation.rotate_box(dim, raw);
        
        return true;
    }
    
    // Sets the crop against the coordinate system of the rotated photo
    public void set_crop(Box crop) {
        Dimensions dim = get_raw_dimensions();
        Orientation orientation = get_orientation();

        Box derotated = orientation.derotate_box(dim, crop);
        
        assert(derotated.get_width() <= dim.width);
        assert(derotated.get_height() <= dim.height);
        
        set_raw_crop(derotated);
    }
    
    public void add_redeye_instance(RedeyeInstance inst_unscaled) {
        Gdk.Rectangle bounds_rect_unscaled = RedeyeInstance.to_bounds_rect(inst_unscaled);
        Gdk.Rectangle bounds_rect_raw = unscaled_to_raw_rect(bounds_rect_unscaled);
        RedeyeInstance inst = RedeyeInstance.from_bounds_rect(bounds_rect_raw);
        
        add_raw_redeye_instance(inst);
    }

    private Gdk.Pixbuf do_redeye(owned Gdk.Pixbuf pixbuf, owned RedeyeInstance inst) {
        /* we remove redeye within a circular region called the "effect
           extent." the effect extent is inscribed within its "bounding
           rectangle." */

        /* for each scanline in the top half-circle of the effect extent,
           compute the number of pixels by which the effect extent is inset
           from the edges of its bounding rectangle. note that we only have
           to do this for the first quadrant because the second quadrant's
           insets can be derived by symmetry */
        double r = (double) inst.radius;
        int[] x_insets_first_quadrant = new int[inst.radius + 1];
        
        int i = 0;
        for (double y = r; y >= 0.0; y -= 1.0) {
            double theta = Math.asin(y / r);
            int x = (int)((r * Math.cos(theta)) + 0.5);
            x_insets_first_quadrant[i] = inst.radius - x;
            
            i++;
        }

        int x_bounds_min = inst.center.x - inst.radius;
        int x_bounds_max = inst.center.x + inst.radius;
        int ymin = inst.center.y - inst.radius;
        ymin = (ymin < 0) ? 0 : ymin;
        int ymax = inst.center.y;
        ymax = (ymax > (pixbuf.height - 1)) ? (pixbuf.height - 1) : ymax;

        /* iterate over all the pixels in the top half-circle of the effect
           extent from top to bottom */
        int inset_index = 0;
        for (int y_it = ymin; y_it <= ymax; y_it++) {
            int xmin = x_bounds_min + x_insets_first_quadrant[inset_index];
            xmin = (xmin < 0) ? 0 : xmin;
            int xmax = x_bounds_max - x_insets_first_quadrant[inset_index];
            xmax = (xmax > (pixbuf.width - 1)) ? (pixbuf.width - 1) : xmax;

            for (int x_it = xmin; x_it <= xmax; x_it++) {
                red_reduce_pixel(pixbuf, x_it, y_it);
            }
            inset_index++;
        }

        /* iterate over all the pixels in the top half-circle of the effect
           extent from top to bottom */
        ymin = inst.center.y;
        ymax = inst.center.y + inst.radius;
        inset_index = x_insets_first_quadrant.length - 1;
        for (int y_it = ymin; y_it <= ymax; y_it++) {  
            int xmin = x_bounds_min + x_insets_first_quadrant[inset_index];
            xmin = (xmin < 0) ? 0 : xmin;
            int xmax = x_bounds_max - x_insets_first_quadrant[inset_index];
            xmax = (xmax > (pixbuf.width - 1)) ? (pixbuf.width - 1) : xmax;

            for (int x_it = xmin; x_it <= xmax; x_it++) {
                red_reduce_pixel(pixbuf, x_it, y_it);
            }
            inset_index--;
        }
        
        return pixbuf;
    }

    private Gdk.Pixbuf red_reduce_pixel(owned Gdk.Pixbuf pixbuf, int x, int y) {
        int px_start_byte_offset = (y * pixbuf.get_rowstride()) +
            (x * pixbuf.get_n_channels());
        
        unowned uchar[] pixel_data = pixbuf.get_pixels();
        
        /* The pupil of the human eye has no pigment, so we expect all
           color channels to be of about equal intensity. This means that at
           any point within the effects region, the value of the red channel
           should be about the same as the values of the green and blue
           channels. So set the value of the red channel to be the mean of the
           values of the red and blue channels. This preserves achromatic
           intensity across all channels while eliminating any extraneous flare
           affecting the red channel only (i.e. the red-eye effect). */
        uchar g = pixel_data[px_start_byte_offset + 1];
        uchar b = pixel_data[px_start_byte_offset + 2];
        
        uchar r = (g + b) / 2;
        
        pixel_data[px_start_byte_offset] = r;
        
        return pixbuf;
    }

    public Gdk.Point unscaled_to_raw_point(Gdk.Point unscaled_point) {
        Orientation unscaled_orientation = get_orientation();
    
        Dimensions unscaled_dims =
            unscaled_orientation.rotate_dimensions(get_dimensions());

        int unscaled_x_offset_raw = 0;
        int unscaled_y_offset_raw = 0;

        Box crop_box;
        if (get_raw_crop(out crop_box)) {
            unscaled_x_offset_raw = crop_box.left;
            unscaled_y_offset_raw = crop_box.top;
        }
        
        Gdk.Point derotated_point =
            unscaled_orientation.derotate_point(unscaled_dims,
            unscaled_point);

        derotated_point.x += unscaled_x_offset_raw;
        derotated_point.y += unscaled_y_offset_raw;

        return derotated_point;
    }
    
    public Gdk.Rectangle unscaled_to_raw_rect(Gdk.Rectangle unscaled_rect) {
        Gdk.Point upper_left = {0};
        Gdk.Point lower_right = {0};
        upper_left.x = unscaled_rect.x;
        upper_left.y = unscaled_rect.y;
        lower_right.x = upper_left.x + unscaled_rect.width;
        lower_right.y = upper_left.y + unscaled_rect.height;
        
        upper_left = unscaled_to_raw_point(upper_left);
        lower_right = unscaled_to_raw_point(lower_right);
        
        if (upper_left.x > lower_right.x) {
            int temp = upper_left.x;
            upper_left.x = lower_right.x;
            lower_right.x = temp;
        }
        if (upper_left.y > lower_right.y) {
            int temp = upper_left.y;
            upper_left.y = lower_right.y;
            lower_right.y = temp;
        }
        
        Gdk.Rectangle raw_rect = {0};
        raw_rect.x = upper_left.x;
        raw_rect.y = upper_left.y;
        raw_rect.width = lower_right.x - upper_left.x;
        raw_rect.height = lower_right.y - upper_left.y;
        
        return raw_rect;
    }

    public PixelTransformationBundle? get_enhance_transformations() {
        Gdk.Pixbuf pixbuf = null;

#if MEASURE_ENHANCE
        Timer fetch_timer = new Timer();
#endif

        try {
            pixbuf = get_pixbuf_with_options(Scaling.for_best_fit(360, false), 
                Photo.Exception.ALL);

#if MEASURE_ENHANCE
            fetch_timer.stop();
#endif
        } catch (Error e) {
            warning("Photo: get_enhance_transformations: couldn't obtain pixbuf to build " + 
                "transform histogram");
            return null;
        }

#if MEASURE_ENHANCE
        Timer analyze_timer = new Timer();
#endif

        PixelTransformationBundle transformations = AutoEnhance.create_auto_enhance_adjustments(pixbuf);

#if MEASURE_ENHANCE
        analyze_timer.stop();
        debug("Auto-Enhance fetch time: %f sec; analyze time: %f sec", fetch_timer.elapsed(),
            analyze_timer.elapsed());
#endif

        return transformations;
    }

    public bool enhance() {
        PixelTransformationBundle transformations = get_enhance_transformations();

        if (transformations == null)
            return false;

#if MEASURE_ENHANCE
        Timer apply_timer = new Timer();
#endif
        lock (row) {
            set_color_adjustments(transformations);
        }
        
#if MEASURE_ENHANCE
        apply_timer.stop();
        debug("Auto-Enhance apply time: %f sec", apply_timer.elapsed());
#endif
        return true;
    }
}

public class LibraryPhotoHoldingTank : DatabaseSourceHoldingTank {
    private Gee.HashMap<File, LibraryPhoto> master_file_map = new Gee.HashMap<File, LibraryPhoto>(
        file_hash, file_equal);
    
    public LibraryPhotoHoldingTank(LibraryPhotoSourceCollection sources,
        SourceHoldingTank.CheckToKeep check_to_keep) {
        base (sources, check_to_keep, Photo.get_photo_key);
    }
    
    public LibraryPhoto? fetch_by_master_file(File file) {
        return master_file_map.get(file);
    }
    
    public LibraryPhoto? fetch_by_md5(string md5) {
        foreach (LibraryPhoto photo in master_file_map.values) {
            if (photo.get_master_md5() == md5) {
                return photo;
            }
        }
        
        return null;
    }
    
    protected override void notify_contents_altered(Gee.Collection<DataSource>? added,
        Gee.Collection<DataSource>? removed) {
        if (added != null) {
            foreach (DataSource source in added) {
                LibraryPhoto photo = (LibraryPhoto) source;
                master_file_map.set(photo.get_master_file(), photo);
                photo.master_replaced.connect(on_photo_master_replaced);
            }
        }
        
        if (removed != null) {
            foreach (DataSource source in removed) {
                LibraryPhoto photo = (LibraryPhoto) source;
                bool is_removed = master_file_map.unset(photo.get_master_file());
                assert(is_removed);
                photo.master_replaced.disconnect(on_photo_master_replaced);
            }
        }
        
        base.notify_contents_altered(added, removed);
    }
    
    private void on_photo_master_replaced(Photo photo, File old_file, File new_file) {
        bool removed = master_file_map.unset(old_file);
        assert(removed);
            
        master_file_map.set(new_file, (LibraryPhoto) photo);
    }
}

public class LibraryPhotoSourceCollection : DatabaseSourceCollection {
    public enum State {
        ONLINE,
        OFFLINE,
        TRASH,
        EDITABLE
    }
    
    private LibraryPhotoHoldingTank trashcan = null;
    private LibraryPhotoHoldingTank offline = null;
    private Gee.HashMap<File, LibraryPhoto> by_master_file = new Gee.HashMap<File, LibraryPhoto>(
        file_hash, file_equal);
    private Gee.HashMap<File, LibraryPhoto> by_editable_file = new Gee.HashMap<File, LibraryPhoto>(
        file_hash, file_equal);
    private Gee.MultiMap<int64?, LibraryPhoto> filesize_to_photo =
        new Gee.TreeMultiMap<int64?, LibraryPhoto>(int64_compare);
    private Gee.HashMap<LibraryPhoto, int64?> photo_to_master_filesize =
        new Gee.HashMap<LibraryPhoto, int64?>(direct_hash, direct_equal, int64_equal);
    private Gee.HashMap<LibraryPhoto, int64?> photo_to_editable_filesize =
        new Gee.HashMap<LibraryPhoto, int64?>(direct_hash, direct_equal, int64_equal);
    private Gee.MultiMap<ImportID?, LibraryPhoto> import_rolls =
        new Gee.TreeMultiMap<ImportID?, LibraryPhoto>(ImportID.compare_func);
    private Gee.TreeSet<ImportID?> sorted_import_ids = new Gee.TreeSet<ImportID?>(ImportID.compare_func);
    
    public virtual signal void trashcan_contents_altered(Gee.Collection<LibraryPhoto>? added,
        Gee.Collection<LibraryPhoto>? removed) {
    }
    
    public virtual signal void offline_contents_altered(Gee.Collection<LibraryPhoto>? added,
        Gee.Collection<LibraryPhoto>? removed) {
    }
    
    public virtual signal void master_file_replaced(LibraryPhoto photo, File old_file, File new_file) {
    }
    
    public virtual signal void import_roll_altered() {
    }
    
    public LibraryPhotoSourceCollection() {
        base("LibraryPhotoSourceCollection", Photo.get_photo_key);
        
        trashcan = new LibraryPhotoHoldingTank(this, check_if_trashed_photo);
        trashcan.contents_altered.connect(on_trashcan_contents_altered);
        
        offline = new LibraryPhotoHoldingTank(this, check_if_offline_photo);
        offline.contents_altered.connect(on_offline_contents_altered);
    }
    
    protected override void notify_contents_altered(Gee.Iterable<DataObject>? added,
        Gee.Iterable<DataObject>? removed) {
        bool import_roll_changed = false;
        if (added != null) {
            foreach (DataObject object in added) {
                LibraryPhoto photo = (LibraryPhoto) object;
                
                by_master_file.set(photo.get_master_file(), photo);
                photo.master_replaced.connect(on_master_replaced);
                
                File? editable = photo.get_editable_file();
                if (editable != null)
                    by_editable_file.set(editable, photo);
                photo.editable_replaced.connect(on_editable_replaced);
                
                int64 master_filesize = photo.get_master_photo_state().filesize;
                int64 editable_filesize = photo.get_editable_photo_state() != null
                    ? photo.get_editable_photo_state().filesize
                    : -1;
                filesize_to_photo.set(master_filesize, photo);
                photo_to_master_filesize.set(photo, master_filesize);
                if (editable_filesize >= 0) {
                    filesize_to_photo.set(editable_filesize, photo);
                    photo_to_editable_filesize.set(photo, editable_filesize);
                }
                
                ImportID import_id = photo.get_import_id();
                if (import_id.is_valid()) {
                    sorted_import_ids.add(import_id);
                    import_rolls.set(import_id, photo);
                    
                    import_roll_changed = true;
                }
            }
        }
        
        if (removed != null) {
            foreach (DataObject object in removed) {
                LibraryPhoto photo = (LibraryPhoto) object;
                
                bool is_removed = by_master_file.unset(photo.get_master_file());
                assert(is_removed);
                photo.master_replaced.disconnect(on_master_replaced);
                
                File? editable = photo.get_editable_file();
                if (editable != null) {
                    is_removed = by_editable_file.unset(photo.get_editable_file());
                    assert(is_removed);
                }
                photo.editable_replaced.disconnect(on_editable_replaced);
                
                int64 master_filesize = photo.get_master_photo_state().filesize;
                int64 editable_filesize = photo.get_editable_photo_state() != null
                    ? photo.get_editable_photo_state().filesize
                    : -1;
                filesize_to_photo.remove(master_filesize, photo);
                photo_to_master_filesize.unset(photo);
                if (editable_filesize >= 0) {
                    filesize_to_photo.remove(editable_filesize, photo);
                    photo_to_editable_filesize.unset(photo);
                }
                
                ImportID import_id = photo.get_import_id();
                if (import_id.is_valid()) {
                    is_removed = import_rolls.remove(import_id, photo);
                    assert(is_removed);
                    if (!import_rolls.contains(import_id))
                        sorted_import_ids.remove(import_id);
                    
                    import_roll_changed = true;
                }
            }
        }
        
        if (import_roll_changed)
            notify_import_roll_altered();
        
        base.notify_contents_altered(added, removed);
    }
    
    private void on_master_replaced(Photo photo, File old_file, File new_file) {
        bool is_removed = by_master_file.unset(old_file);
        assert(is_removed);
        
        by_master_file.set(new_file, (LibraryPhoto) photo);
        
        master_file_replaced((LibraryPhoto) photo, old_file, new_file);
    }
    
    private void on_editable_replaced(Photo photo, File? old_file, File? new_file) {
        if (old_file != null) {
            bool is_removed = by_editable_file.unset(old_file);
            assert(is_removed);
        }
        
        if (new_file != null)
            by_editable_file.set(new_file, (LibraryPhoto) photo);
    }
    
    protected override void items_altered(Gee.Map<DataObject, Alteration> items) {
        Gee.ArrayList<LibraryPhoto> to_trashcan = null;
        Gee.ArrayList<LibraryPhoto> to_offline = null;
        foreach (DataObject object in items.keys) {
            Alteration alteration = items.get(object);
            
            LibraryPhoto photo = (LibraryPhoto) object;
            
            if (alteration.has_detail("image", "master") || alteration.has_detail("image", "editable")) {
                int64 old_master_filesize = photo_to_master_filesize.get(photo);
                int64 old_editable_filesize = photo_to_editable_filesize.has_key(photo)
                    ? photo_to_editable_filesize.get(photo)
                    : -1;
                
                photo_to_master_filesize.unset(photo);
                filesize_to_photo.remove(old_master_filesize, photo);
                if (old_editable_filesize >= 0) {
                    photo_to_editable_filesize.unset(photo);
                    filesize_to_photo.remove(old_editable_filesize, photo);
                }
                
                int64 master_filesize = photo.get_master_photo_state().filesize;
                int64 editable_filesize = photo.get_editable_photo_state() != null
                    ? photo.get_editable_photo_state().filesize
                    : -1;
                photo_to_master_filesize.set(photo, master_filesize);
                filesize_to_photo.set(master_filesize, photo);
                if (editable_filesize >= 0) {
                    photo_to_editable_filesize.set(photo, editable_filesize);
                    filesize_to_photo.set(editable_filesize, photo);
                }
            }
            
            if (!alteration.has_subject("metadata"))
                continue;
            
            if (photo.is_trashed() && !trashcan.contains(photo)) {
                if (to_trashcan == null)
                    to_trashcan = new Gee.ArrayList<LibraryPhoto>();
                
                to_trashcan.add(photo);
                
                // photo can only be in trashcan or offline -- not both
                continue;
            }
            
            if (photo.is_offline() && !offline.contains(photo)) {
                if (to_offline == null)
                    to_offline = new Gee.ArrayList<LibraryPhoto>();
                
                to_offline.add(photo);
            }
        }
        
        if (to_trashcan != null)
            trashcan.unlink_and_hold(to_trashcan);
        
        if (to_offline != null)
            offline.unlink_and_hold(to_offline);
        
        base.items_altered(items);
    }
    
    private void on_trashcan_contents_altered(Gee.Collection<DataSource>? added,
        Gee.Collection<DataSource>? removed) {
        trashcan_contents_altered((Gee.Collection<LibraryPhoto>?) added,
            (Gee.Collection<LibraryPhoto>?) removed);
    }
    
    private bool check_if_trashed_photo(DataSource source, Alteration alteration) {
        return ((LibraryPhoto) source).is_trashed();
    }
    
    private void on_offline_contents_altered(Gee.Collection<DataSource>? added,
        Gee.Collection<DataSource>? removed) {
        offline_contents_altered((Gee.Collection<LibraryPhoto>?) added,
            (Gee.Collection<LibraryPhoto>?) removed);
    }
    
    private bool check_if_offline_photo(DataSource source, Alteration alteration) {
        return ((LibraryPhoto) source).is_offline();
    }
    
    protected virtual void notify_import_roll_altered() {
        import_roll_altered();
    }
    
    public LibraryPhoto fetch(PhotoID photo_id) {
        return (LibraryPhoto) fetch_by_key(photo_id.id);
    }
    
    public LibraryPhoto? fetch_by_master_file(File file) {
        return by_master_file.get(file);
    }
    
    public LibraryPhoto? fetch_by_editable_file(File file) {
        return by_editable_file.get(file);
    }
    
    // Adds photos to both collections if their filesize and timestamp match.  Note that it's possible
    // for a single photo to be added to both collections.
    public void fetch_by_matching_backing(FileInfo info, Gee.Collection<LibraryPhoto> matches_master,
        Gee.Collection<LibraryPhoto> matches_editable) {
        foreach (LibraryPhoto photo in filesize_to_photo.get(info.get_size())) {
            if (photo.get_master_photo_state().matches_file_info(info))
                matches_master.add(photo);
            
            BackingPhotoState? editable = photo.get_editable_photo_state();
            if (editable != null && editable.matches_file_info(info))
                matches_editable.add(photo);
        }
    }
    
    public bool has_basename_filesize_duplicate(string basename, int64 filesize) {
        foreach (LibraryPhoto photo in filesize_to_photo.get(filesize)) {
            if (photo.get_master_file().get_basename() == basename)
                return true;
        }
        
        return false;
    }
    
    // The returned set of ImportID's is sorted from oldest to newest.
    public Gee.SortedSet<ImportID?> get_import_roll_ids() {
        return sorted_import_ids;
    }
    
    public ImportID? get_last_import_id() {
        return sorted_import_ids.size != 0 ? sorted_import_ids.last() : null;
    }
    
    public Gee.Collection<LibraryPhoto?>? get_import_roll(ImportID import_id) {
        return import_rolls.get(import_id);
    }
    
    public LibraryPhoto? get_trashed_by_file(File file) {
        return trashcan.fetch_by_master_file(file);
    }
    
    public LibraryPhoto? get_trashed_by_md5(string md5) {
        return trashcan.fetch_by_md5(md5);
    }
    
    public int get_trashcan_count() {
        return trashcan.get_count();
    }
    
    public Gee.Collection<LibraryPhoto> get_trashcan() {
        return (Gee.Collection<LibraryPhoto>) trashcan.get_all();
    }
    
    public LibraryPhoto? get_offline_by_file(File file) {
        return offline.fetch_by_master_file(file);
    }
    
    public int get_offline_count() {
        return offline.get_count();
    }
    
    public Gee.Collection<LibraryPhoto> get_offline() {
        return (Gee.Collection<LibraryPhoto>) offline.get_all();
    }
    
    public LibraryPhoto? get_state_by_file(File file, out State state) {
        // check hashed locations first
        LibraryPhoto? photo = fetch_by_master_file(file);
        if (photo != null) {
            state = State.ONLINE;
            
            return photo;
        }
        
        photo = fetch_by_editable_file(file);
        if (photo != null) {
            state = State.EDITABLE;
            
            return photo;
        }
        
        if (trashcan.fetch_by_master_file(file) != null) {
            state = State.TRASH;
            
            return photo;
        }
        
        if (offline.fetch_by_master_file(file) != null) {
            state = State.OFFLINE;
            
            return photo;
        }
        
        return null;
    }
    
    // This operation cannot be cancelled; the return value of the ProgressMonitor is ignored.
    // Note that delete_backing dictates whether or not the photos are tombstoned (if deleted,
    // tombstones are not created).
    public void remove_from_app(Gee.Collection<LibraryPhoto> photos, bool delete_backing,
        ProgressMonitor? monitor = null) {
        // only tombstone if the backing is not being deleted
        Gee.HashSet<LibraryPhoto> to_tombstone = !delete_backing ? new Gee.HashSet<LibraryPhoto>()
            : null;
        
        // separate photos into two piles: those in the trash and those not
        Gee.ArrayList<LibraryPhoto> trashed = new Gee.ArrayList<LibraryPhoto>();
        Gee.ArrayList<LibraryPhoto> offlined = new Gee.ArrayList<LibraryPhoto>();
        Gee.ArrayList<LibraryPhoto> not_trashed = new Gee.ArrayList<LibraryPhoto>();
        foreach (LibraryPhoto photo in photos) {
            if (photo.is_trashed())
                trashed.add(photo);
            else if (photo.is_offline())
                offlined.add(photo);
            else
                not_trashed.add(photo);
            
            if (to_tombstone != null)
                to_tombstone.add(photo);
        }
        
        int total_count = photos.size;
        assert(total_count == (trashed.size + offlined.size + not_trashed.size));
        
        // use an aggregate progress monitor, as it's possible there are three steps here
        AggregateProgressMonitor agg_monitor = null;
        if (monitor != null) {
            agg_monitor = new AggregateProgressMonitor(total_count, monitor);
            monitor = agg_monitor.monitor;
        }
        
        if (trashed.size > 0)
            trashcan.destroy_orphans(trashed, delete_backing, monitor);
        
        if (offlined.size > 0)
            offline.destroy_orphans(offlined, delete_backing, monitor);
        
        // untrashed photos may be destroyed outright
        if (not_trashed.size > 0)
            destroy_marked(mark_many(not_trashed), delete_backing, monitor);
        
        if (to_tombstone != null && to_tombstone.size > 0) {
            try {
                Tombstone.entomb_many_photos(to_tombstone);
            } catch (DatabaseError err) {
                AppWindow.database_error(err);
            }
        }
    }
    
    // Do NOT use this function to trash a photo.  This is only used at system initialization.
    // Call LibraryPhoto.trash() instead.
    public void add_many_to_trash(Gee.Collection<LibraryPhoto> photos) {
        trashcan.add_many(photos);
    }
    
    // Do NOT use this function to mark a photo offline.  This is only used at system initialization.
    // Call LibraryPhoto.mark_offline() instead.
    public void add_many_to_offline(Gee.Collection<LibraryPhoto> photos) {
        offline.add_many(photos);
    }
    
    public override bool has_backlink(SourceBacklink backlink) {
        if (base.has_backlink(backlink))
            return true;
        
        if (trashcan.has_backlink(backlink))
            return true;
        
        if (offline.has_backlink(backlink))
            return true;
        
        return false;
    }
    
    public override void remove_backlink(SourceBacklink backlink) {
        trashcan.remove_backlink(backlink);
        offline.remove_backlink(backlink);
        
        base.remove_backlink(backlink);
    }
}

//
// LibraryPhoto
//

public class LibraryPhoto : Photo {
    // Top 16 bits are reserved for Photo
    // Warning: FLAG_HIDDEN and FLAG_FAVORITE have been deprecated for ratings and rating filters.
    private const uint64 FLAG_HIDDEN =      0x0000000000000001;
    private const uint64 FLAG_FAVORITE =    0x0000000000000002;
    private const uint64 FLAG_TRASH =       0x0000000000000004;
    private const uint64 FLAG_OFFLINE =     0x0000000000000008;
    
    public static LibraryPhotoSourceCollection global = null;
    public static MimicManager mimic_manager = null;
    public static LibraryMonitor library_monitor = null;
    
    private bool block_thumbnail_generation = false;
    private OneShotScheduler thumbnail_scheduler = null;
    
    private LibraryPhoto(PhotoRow row) {
        base (row);
        
        thumbnail_scheduler = new OneShotScheduler("LibraryPhoto", generate_thumbnails);
        
        // if marked in a state where they're held in an orphanage, rehydrate their backlinks
        if ((row.flags & (FLAG_TRASH | FLAG_OFFLINE)) != 0)
            rehydrate_backlinks(global, row.backlinks);
        
        if ((row.flags & (FLAG_HIDDEN | FLAG_FAVORITE)) != 0)
            upgrade_rating_flags(row.flags);
    }
    
    public static void init(ProgressMonitor? monitor = null) {
        global = new LibraryPhotoSourceCollection();
        mimic_manager = new MimicManager(global, AppDirs.get_data_subdir("mimics"));
        library_monitor = new LibraryMonitor(AppDirs.get_import_dir(), true, false);
        
        // prefetch all the photos from the database and add them to the global collection ...
        // do in batches to take advantage of add_many()
        Gee.ArrayList<PhotoRow?> all = PhotoTable.get_instance().get_all();
        Gee.ArrayList<LibraryPhoto> all_photos = new Gee.ArrayList<LibraryPhoto>();
        Gee.ArrayList<LibraryPhoto> trashed_photos = new Gee.ArrayList<LibraryPhoto>();
        Gee.ArrayList<LibraryPhoto> offline_photos = new Gee.ArrayList<LibraryPhoto>();
        int count = all.size;
        for (int ctr = 0; ctr < count; ctr++) {
            PhotoRow row = all.get(ctr);
            LibraryPhoto photo = new LibraryPhoto(row);
            uint64 flags = row.flags;
            
            if ((flags & FLAG_TRASH) != 0)
                trashed_photos.add(photo);
            else if ((flags & FLAG_OFFLINE) != 0)
                offline_photos.add(photo);
            else
                all_photos.add(photo);
        }
        
        global.add_many(all_photos, monitor);
        global.add_many_to_trash(trashed_photos);
        global.add_many_to_offline(offline_photos);
        
        // only start discovery after global has been initialized and loaded
        Timeout.add(125, start_discovery);
    }
    
    public static void terminate() {
        if (library_monitor != null)
            library_monitor.close();
    }
    
    private static bool start_discovery() {
        try {
            if (library_monitor != null)
                library_monitor.start_discovery();
        } catch (Error err) {
            warning("Unable to monitor library %s: %s", AppDirs.get_import_dir().get_path(),
                err.message);
        }
        
        return false;
    }
    
    // This accepts a PhotoRow that was prepared with Photo.prepare_for_import and
    // has not already been inserted in the database.  See PhotoTable.add() for which fields are
    // used and which are ignored.  The PhotoRow itself will be modified with the remaining values
    // as they are stored in the database.
    public static ImportResult import_create(PhotoImportParams params, out LibraryPhoto photo) {
        // add to the database
        PhotoID photo_id = PhotoTable.get_instance().add(ref params.row);
        if (photo_id.is_invalid())
            return ImportResult.DATABASE_ERROR;
        
        // create local object but don't add to global until thumbnails generated
        photo = new LibraryPhoto(params.row);
        
        // if photo has tags/keywords, add them now
        if (params.keywords != null) {
            foreach (string keyword in params.keywords)
                Tag.for_name(keyword).attach(photo);
        }
        
        return ImportResult.SUCCESS;
    }
    
    public static void import_failed(LibraryPhoto photo) {
        try {
            PhotoTable.get_instance().remove(photo.get_photo_id());
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        }
    }
    
    private void generate_thumbnails() {
        try {
            ThumbnailCache.import_from_source(this, true);
        } catch (Error err) {
            warning("Unable to generate thumbnails for %s: %s", to_string(), err.message);
        }
        
        // fire signal that thumbnails have changed
        notify_thumbnail_altered();
    }
    
    private override void notify_altered(Alteration alteration) {
        // generate new thumbnails in the background
        if (!block_thumbnail_generation && alteration.has_subject("image"))
            thumbnail_scheduler.at_priority_idle(Priority.LOW);
        
        base.notify_altered(alteration);
    }
    
    public override Gdk.Pixbuf get_preview_pixbuf(Scaling scaling) throws Error {
        Gdk.Pixbuf pixbuf = get_thumbnail(ThumbnailCache.Size.BIG);
        
        return scaling.perform_on_pixbuf(pixbuf, Gdk.InterpType.NEAREST, true);
    }
    
    public override void rotate(Rotation rotation) {
        // block thumbnail generation for this operation; taken care of below
        block_thumbnail_generation = true;
        base.rotate(rotation);
        block_thumbnail_generation = false;

        // because rotations are (a) common and available everywhere in the app, (b) the user expects
        // a level of responsiveness not necessarily required by other modifications, (c) can be
        // performed on multiple images simultaneously, and (d) can't cache a lot of full-sized
        // pixbufs for rotate-and-scale ops, perform the rotation directly on the already-modified 
        // thumbnails.
        try {
            ThumbnailCache.rotate(this, rotation);
        } catch (Error err) {
            // TODO: Mark thumbnails as dirty in database
            warning("Unable to update thumbnails for %s: %s", to_string(), err.message);
        }
        
        notify_thumbnail_altered();
    }
    
    // Returns unscaled thumbnail with all modifications applied applicable to the scale
    public override Gdk.Pixbuf? get_thumbnail(int scale) throws Error {
        return ThumbnailCache.fetch(this, scale);
    }
    
    public LibraryPhoto duplicate() throws Error {
        // clone the master file
        File dupe_file = LibraryFiles.duplicate(get_master_file(), on_duplicate_progress);
        
        // clone the editable (if exists)
        BackingPhotoID dupe_editable_id = BackingPhotoID();
        PhotoFileReader editable_reader = get_editable_reader();
        File? editable_file = (editable_reader != null) ? editable_reader.get_file() : null;
        if (editable_file != null) {
            File dupe_editable = LibraryFiles.duplicate(editable_file, on_duplicate_progress);
            
            BackingPhotoState state = BackingPhotoState();
            DetectedPhotoInformation detected;
            if (query_backing_photo_state(dupe_editable, PhotoFileSniffer.Options.NO_MD5, out state,
                out detected)) {
                BackingPhotoRow editable_row = BackingPhotoTable.get_instance().add(state);
                dupe_editable_id = editable_row.id;
            }
        }
        
        // clone the row in the database for these new backing files
        PhotoID dupe_id = PhotoTable.get_instance().duplicate(get_photo_id(), dupe_file.get_path(),
            dupe_editable_id);
        PhotoRow dupe_row = PhotoTable.get_instance().get_row(dupe_id);
        
        // build the DataSource for the duplicate
        LibraryPhoto dupe = new LibraryPhoto(dupe_row);

        // clone thumbnails
        ThumbnailCache.duplicate(this, dupe);
        
        // add it to the SourceCollection; this notifies everyone interested of its presence
        global.add(dupe);
        
        return dupe;
    }
    
    private void on_duplicate_progress(int64 current, int64 total) {
        spin_event_loop();
    }
    
    private void upgrade_rating_flags(uint64 flags) {
        if ((flags & FLAG_HIDDEN) != 0) {
            set_rating(Rating.REJECTED);
            remove_flags(FLAG_HIDDEN);
        }
        
        if ((flags & FLAG_FAVORITE) != 0) {
            set_rating(Rating.FIVE);
            remove_flags(FLAG_FAVORITE);
        }
    }
    
    // Blotto even!
    public bool is_trashed() {
        return is_flag_set(FLAG_TRASH);
    }
    
    public void trash() {
        add_flags(FLAG_TRASH);
    }
    
    public void untrash() {
        remove_flags(FLAG_TRASH);
    }
    
    public bool is_offline() {
        return is_flag_set(FLAG_OFFLINE);
    }
    
    public void mark_offline() {
        add_flags(FLAG_OFFLINE);
    }
    
    public void mark_online() {
        remove_flags(FLAG_OFFLINE);
    }
    
    public static void mark_many_online_offline(Gee.Collection<LibraryPhoto>? online,
        Gee.Collection<LibraryPhoto>? offline) throws DatabaseError {
        add_remove_many_flags(offline, FLAG_OFFLINE, online, FLAG_OFFLINE);
    }
    
    public override bool internal_delete_backing() throws Error {
        // allow the base classes to work first because delete_original_file() will attempt to
        // remove empty directories as well
        if (!base.internal_delete_backing())
            return false;
        
        delete_original_file();
        
        return true;
    }
    
    public override void destroy() {
        PhotoID photo_id = get_photo_id();

        // remove all cached thumbnails
        ThumbnailCache.remove(this);
        
        // remove from photo table -- should be wiped from storage now (other classes may have added
        // photo_id to other parts of the database ... it's their responsibility to remove them
        // when removed() is called)
        try {
            PhotoTable.get_instance().remove(photo_id);
        } catch (DatabaseError err) {
            AppWindow.database_error(err);
        }
        
        base.destroy();
    }
    
    private void delete_original_file() {
        File file = get_file();
        
        try {
            file.trash(null);
        } catch (Error err) {
            // log error but don't abend, as this is not fatal to operation (also, could be
            // the photo is removed because it could not be found during a verify)
            message("Unable to move original photo %s to trash: %s", file.get_path(), err.message);
        }
        
        // remove empty directories corresponding to imported path, but only if file is located
        // inside the user's Pictures directory
        if (file.has_prefix(AppDirs.get_import_dir())) {
            File parent = file;
            for (int depth = 0; depth < LibraryFiles.DIRECTORY_DEPTH; depth++) {
                parent = parent.get_parent();
                if (parent == null)
                    break;
                
                try {
                    if (!query_is_directory_empty(parent))
                        break;
                } catch (Error err) {
                    warning("Unable to query file info for %s: %s", parent.get_path(), err.message);
                    
                    break;
                }
                
                try {
                    parent.delete(null);
                    debug("Deleted empty directory %s", parent.get_path());
                } catch (Error err) {
                    // again, log error but don't abend
                    message("Unable to delete empty directory %s: %s", parent.get_path(),
                        err.message);
                }
            }
        }
    }
    
    public static bool has_nontrash_duplicate(File? file, string? thumbnail_md5, string? full_md5,
        PhotoFileFormat file_format) {
        PhotoID[]? ids = get_duplicate_ids(file, thumbnail_md5, full_md5, file_format);
        
        if (ids == null || ids.length == 0)
            return false;
        
        foreach (PhotoID id in ids) {
            LibraryPhoto photo = LibraryPhoto.global.fetch(id);
            if (photo != null && !photo.is_trashed())
                return true;
        }
        
        return false;
    }

    protected override bool has_user_generated_metadata() {
        return true; // true because photos always have a rating
    }

    protected override void set_user_metadata_for_export(PhotoMetadata metadata) {
        Gee.List<Tag>? photo_tags = Tag.global.fetch_for_photo(this);
        if(photo_tags != null) {
            Gee.Collection<string> string_tags = new Gee.ArrayList<string>();
            foreach (Tag tag in photo_tags) {
                string_tags.add(tag.get_name());
            }
            metadata.set_keywords(string_tags, false);
        } else
            metadata.set_keywords(null, false);
        
        metadata.set_rating(get_rating());
    }
    
    protected override void apply_user_metadata_for_reimport(PhotoMetadata metadata) {
        Gee.Collection<string>? keywords = metadata.get_keywords();
        if (keywords != null) {
            foreach (string keyword in keywords)
                Tag.for_name(keyword).attach(this);
        }
    }
}

//
// DirectPhoto
//

public class DirectPhotoSourceCollection : DatabaseSourceCollection {
    private Gee.HashMap<File, DirectPhoto> file_map = new Gee.HashMap<File, DirectPhoto>(file_hash, 
        file_equal, direct_equal);
    
    public DirectPhotoSourceCollection() {
        base("DirectPhotoSourceCollection", get_direct_key);
    }
    
    private static int64 get_direct_key(DataSource source) {
        DirectPhoto photo = (DirectPhoto) source;
        PhotoID photo_id = photo.get_photo_id();
        
        return photo_id.id;
    }
    
    public override void notify_items_added(Gee.Iterable<DataObject> added) {
        foreach (DataObject object in added) {
            DirectPhoto photo = (DirectPhoto) object;
            File file = photo.get_file();
            
            assert(!file_map.has_key(file));
            
            file_map.set(file, photo);
        }
        
        base.notify_items_added(added);
    }
    
    public override void notify_items_removed(Gee.Iterable<DataObject> removed) {
        foreach (DataObject object in removed) {
            DirectPhoto photo = (DirectPhoto) object;
            File file = photo.get_file();
            
            bool is_removed = file_map.unset(file);
            assert(is_removed);
        }
        
        base.notify_items_removed(removed);
    }
    
    public ImportResult fetch(File file, out DirectPhoto? photo, bool reset = false) throws Error {
        // fetch from the map first, which ensures that only one DirectPhoto exists for each file
        photo = file_map.get(file);
        if (photo != null) {
            // if a reset is necessary, the database (and the object) need to reset to original
            // easiest way to do this: perform an in-place re-import
            if (reset) {
                PhotoRow updated_row;
                PhotoMetadata metadata;
                if (!photo.prepare_for_reimport_master(out updated_row, out metadata))
                    return ImportResult.FILE_ERROR;
                
                photo.finish_reimport_master(ref updated_row, metadata);
            }
            
            return ImportResult.SUCCESS;
        }
            
        // for DirectPhoto, a fetch on an unknown file is an implicit import into the in-memory
        // database (which automatically adds the new DirectPhoto object to DirectPhoto.global,
        // which be us)
        return DirectPhoto.internal_import(file, out photo);
    }
    
    public DirectPhoto? get_file_source(File file) {
        return file_map.get(file);
    }
}

public class DirectPhoto : Photo {
    private const int PREVIEW_BEST_FIT = 360;
    
    public static DirectPhotoSourceCollection global = null;
    
    private Gdk.Pixbuf preview = null;
    
    private DirectPhoto(PhotoRow row) {
        base (row);
    }
    
    public static void init() {
        global = new DirectPhotoSourceCollection();
    }
    
    public static void terminate() {
    }
    
    // This method should only be called by DirectPhotoSourceCollection.  Use
    // DirectPhoto.global.fetch to import files into the system.
    public static ImportResult internal_import(File file, out DirectPhoto? photo) {
        PhotoImportParams params = new PhotoImportParams(file, ImportID.generate(),
            PhotoFileSniffer.Options.NO_MD5, null, null, null);
        ImportResult result = Photo.prepare_for_import(params);
        if (result != ImportResult.SUCCESS) {
            // this should never happen; DirectPhotoSourceCollection guarantees it.
            assert(result != ImportResult.PHOTO_EXISTS);
            
            photo = null;
            return result;
        }
        
        PhotoTable.get_instance().add(ref params.row);
        
        // create DataSource and add to SourceCollection
        photo = new DirectPhoto(params.row);
        global.add(photo);
        
        return result;
    }

    public override Gdk.Pixbuf get_preview_pixbuf(Scaling scaling) throws Error {
        if (preview == null) {
            preview = get_thumbnail(PREVIEW_BEST_FIT);

            if (preview == null)
                preview = get_pixbuf(scaling);
        }

        return scaling.perform_on_pixbuf(preview, Gdk.InterpType.BILINEAR, true);
    }
    
    public override Gdk.Pixbuf? get_thumbnail(int scale) throws Error {
        return (get_metadata().get_preview_count() == 0) ? null :
            get_orientation().rotate_pixbuf(get_metadata().get_preview(0).get_pixbuf());
    }

    private override void notify_altered(Alteration alteration) {
        preview = null;
        
        base.notify_altered(alteration);
    }

    protected override bool has_user_generated_metadata() {
        // TODO: implement this method
        return false;
    }

    protected override void set_user_metadata_for_export(PhotoMetadata metadata) {
        // TODO: implement this method, see ticket
    }
    
    protected override void apply_user_metadata_for_reimport(PhotoMetadata metadata) {
    }
}

