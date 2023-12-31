#' export list of GAlignments into bam files
#' @description wraper for \link[BiocIO:export]{export} to export list of 
#' GAlignment into bam files.
#' @param objs A list of \link[GenomicAlignments:GAlignments-class]{GAlignments}.
#' @param outPath character(1). Output file path.
#' @return status of export.
#' @export
#' @importFrom Rsamtools asBam
#' @author Jianhong Ou
#' @examples 
#' library(GenomicAlignments)
#' gal1 <- GAlignments(seqnames=Rle("chr1"), pos=1L, cigar="10M",
#'                     strand=Rle(strand(c("+"))), names="a", score=1)
#' galist <- GAlignmentsList(a=gal1)
#' writeListOfGAlignments(galist)

writeListOfGAlignments <- function(objs, outPath="."){
    stopifnot(inherits(objs, c("list", "GAlignmentsList")))
    null <- sapply(objs, function(.ele){
        if(!is(.ele, "GAlignments")){
            stop("All elements in objs must be GAlignments.")
        }
    })
    if(is.null(outPath)){
        stop("invalid outPath.")
    }
    stopifnot(length(outPath)==1)
    if(!file.exists(outPath)){
        dir.create(outPath, showWarnings = FALSE, recursive = TRUE)
    }
    mapply(function(data, n){
        if(length(data)>0){
          try({
             exportBamFile(data, file.path(outPath, paste0(n, ".bam")))
          })
        }else{
          meta <- metadata(data)
          if("file" %in% names(meta)){
            file.copy(from = meta$file, to = file.path(outPath, paste0(n, ".bam")))
            file.copy(from = paste0(meta$file, ".bai"), 
                      to = file.path(outPath, paste0(n, ".bam.bai")))
          }
        }
    }, objs, names(objs))
}

possibleTag <- 
    list("integer"=c("AM", "AS", "CM", "CP", "FI", "H0", "H1", "H2", 
                     "HI", "IH", "MQ", "NH", "NM", "OP", "PQ", "SM",
                     "TC", "UQ"), 
         "character"=c("BC", "BQ", "BZ", "CB", "CC", "CO", "CQ", "CR",
                       "CS", "CT", "CY", "E2", "FS", "LB", "MC", "MD",
                       "MI", "OA", "OC", "OQ", "OX", "PG", "PT", "PU",
                       "Q2", "QT", "QX", "R2", "RG", "RX", "SA", "TS",
                       "U2"),
         "Metadata"=c("RG", "LB", "PG", "PU", "CO"))
fillColumn <- function(x, filler) {
    if (is.null(x))
        filler
    else if (anyNA(x))
        ifelse(is.na(x), filler, x)
    else x
}
formatInt <- function(x){
    formatC(x, format = 'd')
}

exportBamFile <- function(object, con){
    stopifnot(is(object, "GAlignments"))
    sam_path <- sub("bam$", "sam", con, ignore.case = TRUE)
    if(sam_path==con){
        sam_path <- paste0(con, ".sam")
    }
    sam_con <- file(sam_path, "w")
    on.exit(close(sam_con))
    si <- seqinfo(object)
    has_info <-
        seqlevels(si)[!is.na(seqlevels(si)) & !is.na(seqlengths(si))]
    si <- si[has_info]
    if (length(si)) {
        header <- paste0("@SQ",
                         "\tSN:", seqlevels(si),
                         "\tLN:", seqlengths(si))
        has_genome <- !is.na(genome(si))
        header[has_genome] <-  paste0(header[has_genome], "\tAS:",
                                      genome(si)[has_genome])
    }
    custom <- mcols(object)[nchar(names(mcols(object))) == 2L]
    if (length(custom) > 0L && nrow(custom)>0) {
        type.map <- c(integer = "i", numeric = "f", character = "Z",
                      factor = "Z")
        custom.class <- vapply(custom, function(.ele) class(.ele)[1], 
                               FUN.VALUE = "character")
        custom.type <- type.map[custom.class]
        custom.type[names(custom) %in% possibleTag$integer] <- "i"
        custom.type[names(custom) %in% possibleTag$character] <- "Z"
        unknown.class <- custom.class[is.na(custom.type)]
        if (length(unknown.class) > 0L) {
            warning("these classes are not yet valid for BAM tag export: ",
                    paste(unknown.class, collapse=", "))
            custom <- custom[!is.na(custom.type)]
            custom.type <- custom.type[!is.na(custom.type)]
        }
        customMD <- custom[names(custom) %in% possibleTag$Metadata]
        if(length(customMD)){
            tag_ids <- lapply(customMD, unique)
            tag_ids <- lapply(tag_ids, function(.ele) .ele[!is.na(.ele)])
            tag_ids <- paste0("@", rep(names(tag_ids), lengths(tag_ids)),
                              "\tID:", unlist(tag_ids))
            header <- c(header, tag_ids)
        }
    }
    if(length(metadata(object)$header)) header <- metadata(object)$header
    writeLines(header, sam_con)
    chunk <- 100000
    for(i in seq.int(ceiling(length(object)/chunk))){
      idx <- seq.int(chunk)+(i-1)*chunk
      thisObj <- object[idx[idx<=length(object)]]
      thisCustom <- custom[idx[idx<=length(object)], , drop=FALSE]
      emd <- mcols(thisObj)
      aln <- paste(fillColumn(names(thisObj), "*"),# QNAME String
                   formatInt(fillColumn(emd[["flag"]],
                                        ifelse(strand(thisObj) == "-",
                                               "16", "0"))), # FLAG Int
                   seqnames(thisObj),# RNAME String
                   formatInt(start(thisObj)),# POS Int
                   formatInt(fillColumn(emd[["mapq"]], "255")),# MAPQ Int
                   cigar(thisObj), # CIGAR String
                   fillColumn(emd[["mrnm"]], "*"), # RNEXT String
                   formatInt(fillColumn(emd[["mpos"]], "0")), # PNEXT Int
                   formatInt(fillColumn(emd[["isize"]], "0")), # TLEN Int
                   if (is(thisObj, "GappedReads")) thisObj@qseq
                   else fillColumn(emd[["seq"]], "*"), # SEQ String
                   fillColumn(emd[["qual"]], "*"), # QUAL String
                   sep = "\t")
      if (length(thisCustom) > 0L && nrow(thisCustom)>0) {
        tags <- mapply(paste0, names(thisCustom), ":", custom.type, ":",
                       as.list(thisCustom), SIMPLIFY=FALSE)
        tags <- do.call(paste, c(tags, sep = "\t"))
        ## remove the NA values
        tags <- sub("\\t$", "", 
                    sub("..:[ifZ]:NA$", "", 
                        gsub("..:[ifZ]:NA\\t", "", tags)))
        aln <- paste(aln, tags, sep = "\t")
      }
      writeLines(aln, sam_con)
      rm(aln, tags, thisObj, thisCustom)
      gc(verbose = FALSE)
    }
    
    close(sam_con)
    on.exit() ## redefine on.exit
    if(any(seqlengths(si)>536870912)){
        bam <- asBam(sam_path, sub(".bam$", "", con, ignore.case = TRUE),
                     overwrite = TRUE, indexDestination = FALSE)
    }else{
        bam <- asBam(sam_path, sub(".bam$", "", con, ignore.case = TRUE),
                     overwrite = TRUE, indexDestination = TRUE)
    }
    unlink(sam_path)
    invisible(bam)
}
