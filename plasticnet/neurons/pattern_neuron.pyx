from plasticnet.plasticnet cimport *
cimport cython
import pylab
import sys

def dot(what="."):
    import sys
    sys.stdout.write(what)
    sys.stdout.flush()

cdef int randint(int N):
    return <int> (randu()*N)

import numpy as np
cimport numpy as np

cdef class pattern_neuron(neuron):
    cdef public int sequential
    cdef public int pattern_number
    cdef public int rf_size
    cdef public np.ndarray patterns
    cdef public np.ndarray pattern
    cdef public int number_of_patterns
    cdef public double time_between_patterns,time_to_next_pattern

    cpdef _reset(self):
        neuron._reset(self)
        self.time_to_next_pattern=0.0 
        self.pattern_number=-1      
        
    def __init__(self,patterns,time_between_patterns=1.0,sequential=False,shape=None,verbose=False):
        self.patterns=np.ascontiguousarray(np.atleast_2d(np.array(patterns,np.float)))
        if not shape is None:
            self.patterns=self.patterns.reshape(shape)
        
        self.sequential=sequential
        neuron.__init__(self,self.patterns.shape[1]) # number of neurons
        self.number_of_patterns=self.patterns.shape[0]
        self.time_between_patterns=time_between_patterns
        self.verbose=verbose
        self.name='Pattern Neuron'
        self.rf_size=-1

        self._reset()
        self.new_buffer(-1)

        self.save_attrs.extend(['sequential','pattern_number','rf_size',
                    'number_of_patterns','time_between_patterns',
                    'time_to_next_pattern',])
        self.save_data.extend(['patterns','pattern'])


        
    cpdef new_buffer(self,double t):
        pass
        
    cpdef new_pattern(self,double t):
        if self.verbose:
            dot("In new pattern ")

        if not self.sequential:
            if self.verbose:
                dot("random")
            self.pattern_number=<int> (randu()*self.number_of_patterns)
        else:
            if self.verbose:
                dot("sequential")
            self.pattern_number+=1
            if self.pattern_number>=self.number_of_patterns:
                self.new_buffer(t)
                self.pattern_number=0
                
        if self.verbose:
            dot("New pattern %d" % self.pattern_number)
        self.pattern=self.patterns[self.pattern_number]

        self.time_to_next_pattern=t+self.time_between_patterns
        if self.verbose:
            self.print_pattern()
            dot("Time to next pattern: %f" % self.time_to_next_pattern)
        
    def print_pattern(self):
        cdef int i
        cdef double *pattern=<double *>self.pattern.data
        print("[")
        for i in range(self.N):
            print(pattern[i])
        print("]")
        sys.stdout.flush()
            

    @cython.cdivision(True)
    @cython.boundscheck(False) # turn of bounds-checking for entire function
    cpdef update(self,double t,simulation sim):
        cdef double r
        cdef int i,j
        cdef double *y=<double *>self.linear_output.data
        cdef double *z=<double *>self.output.data
        cdef double *pattern
        if self.verbose:
            dot("In Update pattern neuron")
        if t>=(self.time_to_next_pattern-1e-6):  # the 1e-6 is because of binary represenation offsets
            if self.verbose:
                print self.name
                print type(self)
                dot("I")
                
            self.new_pattern(t)
        pattern=<double *>self.pattern.data    

        if self.verbose:
            dot("-")

        for i in range(self.N):
            if self.verbose:
                dot(".")
            y[i]=pattern[i]
            z[i]=pattern[i]
 
def asdf_load_images(fname):
    import asdf
    import warnings
    warnings.filterwarnings("ignore",category=asdf.exceptions.AsdfDeprecationWarning)

    var={}
    with asdf.open(fname) as af:
        var['im_scale_shift']=af.tree['im_scale_shift']
        var['im']=[np.array(_) for _ in af.tree['im']]

    return var


def hdf5_load_images(fname):
    import h5py,os
    
    if not os.path.exists(fname):
        raise ValueError,"File does not exist: %s" % fname
    f=h5py.File(fname,'r')
    var={}
    var['im_scale_shift']=list(f.attrs['im_scale_shift'])
    N=len(f.keys())
    var['im']=[]
    for i in range(N):
        var['im'].append(np.array(f['image%d' % i]))

    f.close()

    return var

cdef class natural_images(pattern_neuron):
    cdef public int buffer_size
    cdef public object im
    cdef public object filename
    cdef int number_of_pics
    cdef int images_loaded
    cdef int p,r,c
    cdef public int use_other_channel
    cdef natural_images other_channel
    
    cpdef _reset(self):
        pattern_neuron._reset(self)
        self.p=self.r=self.c=-1
        
    def __init__(self,fname='hdf5/bbsk081604_norm.hdf5',rf_size=13,
                     time_between_patterns=1.0,other_channel=None,
                     verbose=False,
                     ):

        self.sequential=True
        self.filename=fname
        if not other_channel is None:
            self.other_channel=<natural_images>other_channel
            self.use_other_channel=True
        else:
            self.use_other_channel=False

        self.images_loaded=False

        
        pattern_neuron.__init__(self,np.zeros((1,rf_size*rf_size),np.float),
                            time_between_patterns=time_between_patterns,sequential=True,verbose=verbose)
    
    
        self.rf_size=rf_size
        self.pattern=self.patterns[0]
        self.name='Natural Images'
        
        if verbose:
            print "Read %d images from %s" % (len(self.im),fname)
            for im in self.im:
                print "[%d,%d]" % (im.shape[0],im.shape[1]),
            sys.stdout.flush()
    
        self.save_attrs.extend(['buffer_size','use_other_channel','filename'])
        #self.save_data.extend(['',])

    cdef load_images(self):
        if any([self.filename.endswith(ext) for ext in ['.hdf5','h5','hd5']]):
            image_data=hdf5_load_images(self.filename)
        elif self.filename.endswith('.asdf'):
            image_data=asdf_load_images(self.filename)
        else:
            raise ValueError('Image type not implemented '+self.filename)
        
        self.im=[arr.astype(float)*image_data['im_scale_shift'][0]+image_data['im_scale_shift'][1] 
                                for arr in image_data['im']]
        del image_data
        self.images_loaded=True

    cpdef _clean(self):
        del self.im
        self.images_loaded=False

    cpdef new_pattern(self,double t):
        cdef int i,j,k,num_rows,num_cols,r,c,p,offset,count
        cdef np.ndarray pic
        cdef double *pic_ptr
        cdef double *pattern
                
        if not self.images_loaded:
            self.load_images()

        pattern=<double *>self.pattern.data    
                
        cdef int number_of_pictures=len(self.im)
                
        if not self.use_other_channel:
            p=randint(number_of_pictures)
        else:
            p=self.other_channel.p % number_of_pictures
        
        pic=self.im[p]
        pic_ptr=<double *> pic.data
            
        num_rows,num_cols=pic.shape[0],pic.shape[1]
        
        if not self.use_other_channel:
            r,c=randint(num_rows-self.rf_size),randint(num_cols-self.rf_size)
        else:
            r,c=self.other_channel.r,self.other_channel.c

        if self.verbose:
            print p,r,c

        self.p=p
        self.c=c
        self.r=r

        count=0
        for i in range(self.rf_size):
            for j in range(self.rf_size):
                offset=(r+i)*num_cols+(c+j)
                
                pattern[count]=pic_ptr[offset]
                count+=1
                if self.verbose:
                    print "[%d,%d]" % (offset,count),
                    sys.stdout.flush()



        if self.verbose:
            print            
            sys.stdout.flush()

        self.time_to_next_pattern=t+self.time_between_patterns
        if self.verbose:
            print "New pattern t=%f" % t
            self.print_pattern()
            print "Time to next pattern: %f" % self.time_to_next_pattern
            sys.stdout.flush()
    
    